{-# LANGUAGE RecordWildCards #-}

module Main
       ( main
       ) where

import           Universum

import           Control.Exception.Safe (handle)
import           Data.Maybe (fromMaybe)
import           Formatting (sformat, shown, (%))
import qualified Network.Transport.TCP as TCP (TCPAddr (..))
import qualified System.IO.Temp as Temp

import           Ntp.Client (NtpConfiguration)

import           Pos.Chain.Genesis as Genesis (Config (..), ConfigurationError)
import           Pos.Chain.Txp (TxpConfiguration)
import           Pos.Chain.Update (updateConfiguration)
import qualified Pos.Client.CLI as CLI
import           Pos.Context (NodeContext (..))
import           Pos.DB.DB (initNodeDBs)
import           Pos.DB.Txp (txpGlobalSettings)
import           Pos.Infra.Diffusion.Types (Diffusion, hoistDiffusion)
import           Pos.Infra.Network.Types (NetworkConfig (..), Topology (..),
                     topologyDequeuePolicy, topologyEnqueuePolicy,
                     topologyFailurePolicy)
import           Pos.Launcher (HasConfigurations, NodeParams (..),
                     NodeResources (..), WalletConfiguration,
                     bracketNodeResources, loggerBracket, lpConsoleLog,
                     runNode, runRealMode, withConfigurations)
import           Pos.Util (logException)
import           Pos.Util.CompileInfo (HasCompileInfo, withCompileInfo)
import           Pos.Util.Config (ConfigurationException (..))
import           Pos.Util.Trace (fromTypeclassWlog, noTrace)
import           Pos.Util.UserSecret (usVss)
import           Pos.Util.Wlog (LoggerName, logInfo)
import           Pos.WorkMode (EmptyMempoolExt, RealMode)

import           AuxxOptions (AuxxAction (..), AuxxOptions (..),
                     AuxxStartMode (..), getAuxxOptions)
import           Mode (AuxxContext (..), AuxxMode, realModeToAuxx)
import           Plugin (auxxPlugin, rawExec)
import           Repl (PrintAction, WithCommandAction (..), withAuxxRepl)

loggerName :: LoggerName
loggerName = "auxx"

-- 'NodeParams' obtained using 'CLI.getNodeParams' are not perfect for
-- Auxx, so we need to adapt them slightly.
correctNodeParams :: AuxxOptions -> NodeParams -> IO (NodeParams, Bool)
correctNodeParams AuxxOptions {..} np = do
    (dbPath, isTempDbUsed) <- case npDbPathM np of
        Nothing -> do
            tempDir <- Temp.getCanonicalTemporaryDirectory
            dbPath <- Temp.createTempDirectory tempDir "nodedb"
            logInfo $ sformat ("Temporary db created: "%shown) dbPath
            return (dbPath, True)
        Just dbPath -> do
            logInfo $ sformat ("Supplied db used: "%shown) dbPath
            return (dbPath, False)
    let np' = np
            { npNetworkConfig = networkConfig
            , npRebuildDb = npRebuildDb np || isTempDbUsed
            , npDbPathM = Just dbPath }
    return (np', isTempDbUsed)
  where
    topology = TopologyAuxx aoPeers
    networkConfig =
        NetworkConfig
        { ncDefaultPort = 3000
        , ncSelfName = Nothing
        , ncEnqueuePolicy = topologyEnqueuePolicy topology
        , ncDequeuePolicy = topologyDequeuePolicy topology
        , ncFailurePolicy = topologyFailurePolicy topology
        , ncTopology = topology
        , ncTcpAddr = TCP.Unaddressable
        , ncCheckPeerHost = True
        }

runNodeWithSinglePlugin ::
       (HasConfigurations, HasCompileInfo)
    => Genesis.Config
    -> TxpConfiguration
    -> NodeResources EmptyMempoolExt
    -> (Diffusion AuxxMode -> AuxxMode ())
    -> Diffusion AuxxMode -> AuxxMode ()
runNodeWithSinglePlugin genesisConfig txpConfig nr plugin =
    runNode genesisConfig txpConfig nr [ ("runNodeWithSinglePlugin", plugin) ]

action :: HasCompileInfo => AuxxOptions -> Either WithCommandAction Text -> IO ()
action opts@AuxxOptions {..} command = do
    let pa = either printAction (const putText) command
    case aoStartMode of
        Automatic
            ->
                handle @_ @ConfigurationException (\_ -> runWithoutNode pa)
              . handle @_ @ConfigurationError (\_ -> runWithoutNode pa)
              $ withConfigurations noTrace
                                   Nothing
                                   cnaDumpGenesisDataPath
                                   cnaDumpConfiguration
                                   conf
                                   (runWithConfig pa)
        Light
            -> runWithoutNode pa
        _   -> withConfigurations noTrace
                                  Nothing
                                  cnaDumpGenesisDataPath
                                  cnaDumpConfiguration
                                  conf
                                  (runWithConfig pa)
  where
    runWithoutNode :: PrintAction IO -> IO ()
    runWithoutNode printAction = printAction "Mode: light" >> rawExec Nothing Nothing Nothing opts Nothing command

    runWithConfig
        :: HasConfigurations
        => PrintAction IO
        -> Genesis.Config
        -> WalletConfiguration
        -> TxpConfiguration
        -> NtpConfiguration
        -> IO ()
    runWithConfig printAction genesisConfig _walletConfig txpConfig _ntpConfig = do
        printAction "Mode: with-config"
        (nodeParams, tempDbUsed) <- (correctNodeParams opts . fst) =<< CLI.getNodeParams
            fromTypeclassWlog
            loggerName
            cArgs
            nArgs
            (configGeneratedSecrets genesisConfig)

        let toRealMode :: AuxxMode a -> RealMode EmptyMempoolExt a
            toRealMode auxxAction = do
                realModeContext <- ask
                let auxxContext =
                        AuxxContext
                        { acRealModeContext = realModeContext
                        , acTempDbUsed = tempDbUsed }
                lift $ runReaderT auxxAction auxxContext
            vssSK = fromMaybe (error "no user secret given")
                              (npUserSecret nodeParams ^. usVss)
            sscParams = CLI.gtSscParams cArgs vssSK (npBehaviorConfig nodeParams)

        bracketNodeResources genesisConfig
                             nodeParams
                             sscParams
                             (txpGlobalSettings genesisConfig txpConfig)
                             (initNodeDBs genesisConfig) $ \nr ->
            let NodeContext {..} = nrContext nr
                modifier = if aoStartMode == WithNode
                           then runNodeWithSinglePlugin genesisConfig txpConfig nr
                           else identity
                auxxModeAction = modifier (auxxPlugin genesisConfig txpConfig opts command)
             in runRealMode updateConfiguration genesisConfig txpConfig nr $ \diffusion ->
                    toRealMode (auxxModeAction (hoistDiffusion realModeToAuxx toRealMode diffusion))

    cArgs@CLI.CommonNodeArgs {..} = aoCommonNodeArgs
    conf = CLI.configurationOptions (CLI.commonArgs cArgs)
    nArgs =
        CLI.NodeArgs
            { behaviorConfigPath = Nothing
            }

main :: IO ()
main = withCompileInfo $ do
    opts <- getAuxxOptions
    let disableConsoleLog
            | Repl <- aoAction opts =
                  -- Logging in the REPL disrupts the prompt,
                  -- so we disable it.
                  -- TODO: When LW-25 is resolved we also want
                  -- to be able to enable logging in REPL using
                  -- a Haskeline-compatible print action.
                  \lp -> lp { lpConsoleLog = Just False }
            | otherwise = identity
        loggingParams = disableConsoleLog $
            CLI.loggingParams loggerName (aoCommonNodeArgs opts)
    loggerBracket "auxx" loggingParams . logException "auxx" $ do
        let runAction a = action opts a
        case aoAction opts of
            Repl    -> withAuxxRepl $ \c -> runAction (Left c)
            Cmd cmd -> runAction (Right cmd)
