{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Database.Beam.Sqlite.Connection where

import           Database.Beam.Backend
import           Database.Beam.Sqlite.Syntax
import           Database.Beam.Sqlite.Types

import           Database.SQLite.Simple ( Connection, ToRow(..), FromRow(..)
                                        , SQLData, field
                                        , withStatement, bind, nextRow)
import           Database.SQLite.Simple.Internal (RowParser(RP), unRP)
import           Database.SQLite.Simple.Ok (Ok(..))
import           Database.SQLite.Simple.Types (Null)

import           Control.Monad.Free.Church
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Monad.Trans

import           Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.DList as D
import           Data.String

newtype SqliteM a = SqliteM { runSqliteM :: ReaderT Connection IO a }
  deriving (Monad, Functor, Applicative, MonadIO)

newtype BeamSqliteParams = BeamSqliteParams [SQLData]
instance ToRow BeamSqliteParams where
  toRow (BeamSqliteParams x) = x

newtype BeamSqliteRow a = BeamSqliteRow a
instance FromBackendRow Sqlite a => FromRow (BeamSqliteRow a) where
  fromRow = BeamSqliteRow <$> runF (fromBackendRow :: FromBackendRowM Sqlite a) finish step
      where
        finish x = pure x

        step :: FromBackendRowF Sqlite (RowParser a) -> RowParser a
        step (ParseOneField next) =
            field >>= next
        step (PeekField next) =
            RP $ do
              ro <- ask
              st <- get
              case runStateT (runReaderT (unRP field) ro) st of
                Ok (a, _) -> unRP (next (Just a))
                _ -> unRP (next Nothing)
        step (CheckNextNNull n next) =
            RP $ do
              ro <- ask
              st <- get
              case runStateT (runReaderT (unRP (replicateM_ n (field :: RowParser Null))) ro) st of
                Ok ((), _) -> unRP (next True)
                _ -> unRP (next False)

runSqlite :: Connection -> SqliteM a -> IO a
runSqlite conn x = runReaderT (runSqliteM x) conn

instance MonadBeam SqliteCommandSyntax Sqlite SqliteM where
  runReturningMany (SqliteCommandSyntax (SqliteSyntax cmd vals)) action =
      SqliteM $ do
        conn <- ask
        liftIO . withStatement conn (fromString (BL.unpack (toLazyByteString cmd))) $ \stmt ->
            do bind stmt (BeamSqliteParams (D.toList vals))
               let nextRow' = liftIO (nextRow stmt) >>= \x ->
                              case x of
                                Nothing -> pure Nothing
                                Just (BeamSqliteRow row) -> pure row
               runReaderT (runSqliteM (action nextRow')) conn