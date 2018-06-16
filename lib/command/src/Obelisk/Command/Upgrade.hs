{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Obelisk.Command.Upgrade where

import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import qualified Data.Map as Map
import Data.Semigroup ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (getExecutablePath)
import System.FilePath
import System.Posix.Process (executeFile)
import System.Process (proc)

import Obelisk.App (MonadObelisk)
import Obelisk.CliApp
import Obelisk.Command.Utils

import Obelisk.Command.Project (toImplDir)
import Obelisk.Command.Project (findProjectObeliskCommand)
import Obelisk.Command.Thunk (updateThunk)

import Obelisk.Migration

data MigrationGraph
  = MigrationGraph_ObeliskUpgrade
  | MigrationGraph_ObeliskHandoff
  deriving (Eq, Show)

graphName :: MigrationGraph -> Text
graphName = \case
  MigrationGraph_ObeliskHandoff -> "obelisk-handoff"
  MigrationGraph_ObeliskUpgrade -> "obelisk-upgrade"

fromGraphName :: Text -> MigrationGraph
fromGraphName = \case
  "obelisk-handoff" -> MigrationGraph_ObeliskHandoff
  "obelisk-upgrade" -> MigrationGraph_ObeliskUpgrade
  _ -> error "Invalid graph name specified"


ensureCleanProject :: MonadObelisk m => FilePath -> m ()
ensureCleanProject project = ensureCleanGitRepo project False "Cannot upgrade with uncommited changes"

-- | Decide whether we (ambient ob) should handoff to project obelisk before performing upgrade
decideHandOffToProjectOb :: MonadObelisk m => FilePath ->  m Bool
decideHandOffToProjectOb project = do
  ensureCleanProject project
  updateThunk (toImplDir project) $ \projectOb -> do
    getMigrationGraph projectOb MigrationGraph_ObeliskHandoff >>= \case
      Nothing -> do
        putLog Warning "Project obelisk is too old (has no migration graph); won't handoff"
        return False
      Just _ -> do
        projectHash <- computeVertexHash projectOb MigrationGraph_ObeliskHandoff projectOb
        (ambientGraph, ambientHash) <- getAmbientObInfo

        case hasVertex projectHash ambientGraph of
          False -> do
            putLog Warning "Cannot find project ob in ambient ob's migration graph; handing off anyway"
            return True
          True -> case findPath projectHash ambientHash ambientGraph of
            Nothing -> do
              putLog Warning "No migration path between project and ambient ob; handing off anyway"
              return True
            Just ex -> do
              actions <- sequence $ fmap (getEdge ambientGraph) ex
              let dontHandoff = or $ flip fmap actions $ \case
                    "True" -> True
                    _ -> False
              return $ not dontHandoff
  where
    getAmbientObInfo = do
      ambientOb <- getAmbientOb
      getMigrationGraph ambientOb MigrationGraph_ObeliskHandoff >>= \case
        Nothing -> do
          failWith "Ambient ob has no migration (this can't be possible)"
        Just (m, _, ambientHash) -> do
          unless (hasVertex ambientHash m) $
            failWith "Ambient ob's hash is not in its own graph"
          return (m, ambientHash)

-- | Return the path to the current ('ambient') obelisk process Nix directory
getAmbientOb :: MonadObelisk m => m FilePath
getAmbientOb = takeDirectory . takeDirectory <$> liftIO getExecutablePath

getEdge :: MonadObelisk m => Migration action -> (Hash, Hash) -> m action
getEdge (Migration _ h) e = case Map.lookup e h of
  Just a -> return a
  Nothing -> failWith $ "Edge " <> T.pack (show e) <> " not found"

upgradeObelisk :: MonadObelisk m => FilePath -> Text -> Maybe Hash -> m ()
upgradeObelisk project gitBranch migrateOnlyFromHash =
  case migrateOnlyFromHash of
    Nothing -> do  -- This is user invoked upgrade command
      ensureCleanProject project
      fromHash <- updateObelisk project gitBranch
      handOffToNewOb project gitBranch fromHash
    Just fromHash ->
      migrateObelisk project gitBranch fromHash

updateObelisk :: MonadObelisk m => FilePath -> Text -> m Hash
updateObelisk project gitBranch =
  withSpinner' ("Updating Obelisk thunk", Just . ("Updated Obelisk thunk to hash " <>)) $
    updateThunk (toImplDir project) $ \obImpl -> do
      ob <- getAmbientOb
      fromHash <- computeVertexHash ob MigrationGraph_ObeliskUpgrade obImpl
      callProcessAndLogOutput (Debug, Debug) $
        git1 obImpl ["checkout", T.unpack gitBranch]
      callProcessAndLogOutput (Debug, Debug) $
        git1 obImpl ["pull"]
      return fromHash

handOffToNewOb :: MonadObelisk m => FilePath -> Text -> Hash -> m ()
handOffToNewOb project gitBranch fromHash = do
  impl <- withSpinner' ("Preparing for handoff", Just . ("Handing off to new obelisk " <>) . T.pack) $
    findProjectObeliskCommand project >>= \case
      Nothing -> failWith "Not an Obelisk project"
      Just impl -> pure impl
  -- TODO: respect DRY (see command.hs; maybe reuse Handoff type)
  -- TODO: Should this be `ob internal migrate-only-from-hash` instead?
  let opts = ["upgrade"]
        <> ["--migrate-only-from-hash", T.unpack fromHash]
        <> [T.unpack gitBranch]
  liftIO $ executeFile impl False ("--no-handoff" : opts) Nothing

-- TODO: When this function fails, we should revert the thunk update.
migrateObelisk :: MonadObelisk m => FilePath -> Text -> Hash -> m ()
migrateObelisk project gitBranch fromHash = void $ withSpinner' ("Migrating to new Obelisk", Just) $ do
  updateThunk (toImplDir project) $ \obImpl -> do
    toHash <- computeVertexHash obImpl MigrationGraph_ObeliskUpgrade obImpl
    (g, _, _) <- getMigrationGraph obImpl MigrationGraph_ObeliskUpgrade >>= \case
      Nothing -> failWith "New obelisk has no migration metadata"
      Just m -> pure m

    unless (hasVertex fromHash g) $ do
      failWith $ "Current obelisk hash " <> fromHash <> " missing in migration graph of new obelisk"
    unless (hasVertex toHash g) $ do
      -- This usually means that the target obelisk branch does not have
      -- migration vertex for its latest commit; typically due to developer
      -- negligence.
      failWith $ "New obelisk hash " <> toHash <> " missing in its migration graph"

    if fromHash == toHash
      then do
        pure $ "No upgrade available (new Obelisk is the same)"
      else do
        putLog Debug $ "Migrating from " <> fromHash <> " to " <> toHash
        case runMigration g fromHash toHash of
          Nothing -> do
            failWith "Unable to find migration path"
          Just [] -> do
            pure $ "No migrations necessary between " <> fromHash <> " and " <> toHash
          Just actions -> do
            putLog Notice $ "Migrations from '" <> gitBranch <> "' are shown below:\n"
            forM_ actions $ \(hash, a) -> do
              -- TODO: Colorize, prettify output to emphasize better.
              putLog Notice $ "==== [" <> hash <> "] ==="
              putLog Notice a
            putLog Notice $ "Please commit the changes to the project, and manually perform the above migrations to make your project work with the upgraded Obelisk.\n"
            pure $ "Migrated from " <> fromHash <> " to " <> toHash <> " (" <> T.pack (show $ length actions) <> " actions)"

-- | Get the migration graph for project, along with the first and last hash.
getMigrationGraph
  :: MonadObelisk m => FilePath -> MigrationGraph -> m (Maybe (Migration Text, Hash, Hash))
getMigrationGraph project graph = runMaybeT $ do
  let name = graphName graph
  putLog Debug $ "Reading migration graph " <> name <> " from " <> T.pack project
  g <- MaybeT $ liftIO $ readGraph T.pack  (migrationDir project) name
  first <- MaybeT $ pure $ getFirst $ _migration_graph g
  last' <- MaybeT $ pure $ getLast $ _migration_graph g
  pure $ (g, first, last')

computeVertexHash :: MonadObelisk m => FilePath -> MigrationGraph -> FilePath -> m Hash
computeVertexHash obDir graph repoDir = fmap T.pack $ readProcessAndLogStderr Error $
  proc "sh" [hashScript, repoDir]
  where
    hashScript = (migrationDir obDir) </> (T.unpack (graphName graph) <> ".hash.sh")

migrationDir :: FilePath -> FilePath
migrationDir project = project </> "migration"