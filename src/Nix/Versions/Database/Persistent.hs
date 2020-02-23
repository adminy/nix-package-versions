 {-# LANGUAGE OverloadedStrings #-}
 {-# LANGUAGE NamedFieldPuns #-}
{-|
This file handles saving and retrieving Database types from and to persistent storage.
It uses SQLite.
-}

module Nix.Versions.Database.Persistent where

import Control.Exception (tryJust)
import Data.Maybe (fromMaybe)
import Data.Text (Text, pack, unpack)
import Data.Time.Calendar (Day(..), toModifiedJulianDay)
import Nix.Versions.Database (PackageDB(..), VersionInfo(..))
import Nix.Versions.Types (Hash(..), Version(..), Name(..), Commit(..))

import Database.SQLite.Simple (ToRow(toRow), FromRow(fromRow), SQLData(..))
import qualified Database.SQLite.Simple as SQL

-- Constants

db_FILE_NAME = "SQL_DATABASE.db"
db_PACKAGE_NAMES = "PACKAGE_NAMES"
db_PACKAGE_VERSIONS = "PACKAGE_VERSIONS"

-- | Get a connection and make sure that
connect :: IO SQL.Connection
connect = do
    conn <- SQL.open db_FILE_NAME
    -- Enable foreign key constraints.
    -- It's really weird that they would otherwise just not work.
    SQL.execute_ conn "PRAGMA foreign_keys = ON"
    ensureTablesAreCreated conn
    return conn

ensureTablesAreCreated :: SQL.Connection -> IO ()
ensureTablesAreCreated conn = do
    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_PACKAGE_NAMES <> " "
                        <> "( PACKAGE_NAME TEXT PRIMARY KEY"
                        <> ")"

    SQL.execute_ conn $ "CREATE TABLE IF NOT EXISTS  " <> db_PACKAGE_VERSIONS <> " "
                        <> "( PACKAGE_NAME TEXT NOT NULL"
                        <> ", VERSION_NAME TEXT NOT NULL"
                        <> ", REVISION_HASH TEXT NOT NULL"
                        <> ", DESCRIPTION TEXT"
                        <> ", NIXPATH TEXT"
                        <> ", DAY INTEGER NOT NULL"
                        <> ", PRIMARY KEY (PACKAGE_NAME, VERSION_NAME)"
                        <> ", FOREIGN KEY (PACKAGE_NAME) REFERENCES " <> db_PACKAGE_NAMES <> "(PACKAGE_NAME)"
                        <> ")"

versions :: SQL.Connection -> Name -> IO [(Version, VersionInfo)]
versions conn (Name name) = do
    results <- SQL.query
        conn
        ("SELECT * FROM " <> db_PACKAGE_VERSIONS <> " WHERE PACKAGE_NAME = ?")
        [unpack name]
    return $ toVersionAndInfo <$> results
        where
            toVersionAndInfo (SQLPackageVersion (_, version, info)) = (version, info)

-- | Save the DB in the database
persistPackage :: SQL.Connection -> SQLPackageVersion -> IO ()
persistPackage conn versionInfo = do
    result <- tryJust isConstraintError  insertVersion
    case result of
        Left () -> do
            insertPackageName
            insertVersion
        Right _ -> return ()
    where
        insertVersion = SQL.execute conn
            ("INSERT OR REPLACE INTO " <> db_PACKAGE_VERSIONS <> " VALUES (?,?,?,?,?,?)")
            versionInfo

        insertPackageName = SQL.execute conn
            ("INSERT OR REPLACE INTO " <> db_PACKAGE_NAMES <> " VALUES (?)")
            (SQLPackageName name)

        SQLPackageVersion (name, _, _) = versionInfo

        isConstraintError :: SQL.SQLError -> Maybe ()
        isConstraintError err =
            if SQL.sqlError err == SQL.ErrorConstraint
               then Just ()
               else Nothing

newtype SQLPackageName = SQLPackageName Name

instance ToRow SQLPackageName where
    toRow (SQLPackageName (Name name)) = [SQLText name]

instance FromRow SQLPackageName where
    fromRow = (SQLPackageName . Name) <$> SQL.field

newtype SQLPackageVersion = SQLPackageVersion (Name, Version, VersionInfo)

instance ToRow SQLPackageVersion where
    toRow (SQLPackageVersion (name, version, VersionInfo { revision, description , nixpath, date })) =
        [ SQLText $ fromName name
        , SQLText $ fromVersion version
        , SQLText $ fromHash revision
        , nullable $ SQLText <$> description
        , nullable $ SQLText . pack <$> nixpath
        , SQLInteger $ fromInteger $ toModifiedJulianDay date
        ]

nullable :: Maybe SQLData -> SQLData
nullable = fromMaybe SQLNull

instance FromRow SQLPackageVersion where
    fromRow = create
            <$> SQL.field
            <*> SQL.field
            <*> SQL.field
            <*> SQL.field
            <*> SQL.field
            <*> SQL.field
        where
            create :: Text -> Text -> Text -> Maybe Text -> Maybe Text -> Integer -> SQLPackageVersion
            create name version revision description nixpath date =
                SQLPackageVersion
                    ( Name name
                    , Version version
                    , VersionInfo
                        { revision = Hash revision
                        , description = description
                        , nixpath = unpack <$> nixpath
                        , date = ModifiedJulianDay $ fromInteger date
                        }
                    )

