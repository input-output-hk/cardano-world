{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Cardano.CLI.Faucet.Web (userAPI, server, run, SiteVerifyRequest(..)) where

import Cardano.Api (CardanoEra, IsShelleyBasedEra, ShelleyBasedEra, TxInMode(TxInMode), getTxId, TxId, AddressAny, Lovelace(Lovelace), IsCardanoEra)
import Cardano.CLI.Faucet.Misc
import Cardano.CLI.Faucet.TxUtils
import Cardano.CLI.Faucet.Types
import Cardano.CLI.Faucet.Utils
import Cardano.CLI.Run.Friendly (friendlyTxBS)
import Cardano.CLI.Types
import Cardano.Prelude
import Control.Concurrent.STM (writeTQueue, TMVar, takeTMVar, putTMVar, readTMVar)
import Control.Monad.Trans.Except.Extra (left)
import Data.HashMap.Strict qualified as HM
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock
import Servant
import Servant.Client
import Network.HTTP.Client.TLS (newTlsManagerWith, tlsManagerSettings)
import Prelude ()
import Network.Socket (SockAddr)
import Cardano.CLI.Shelley.Run.Transaction

-- https://faucet.cardano-testnet.iohkdev.io/send-money/addr_test1vr3g684kyarnug89c7p7gqxr5y8t45g7q4ge4u8hghndvugn6yn5s?apiKey=&g-recaptcha-response=03AGdBq24qppnXuY6fIcCG2Hrpqxfp0V9Xd3oDqElSikr38sAuPMmpO4dKke9O0NzhtFnv_-cXVSs8h4loNDBDeM3rIb5UDHmoCsIylCHXmOovfDIOWM7417-9nW_8XegF7murR2CpVGDp8js7L33ygKqbPUus8AQncJ26AikCDiDNOe7_u6pHb20pR_a8a2cjfcRu6Ptrq8uTWxk2QiinvSctAZbnyTRscupJNDVvoJ1l52LNXOFNTFowRuyaRu1K9mLAJvbwy5n1il_05UGWRNvK3raCUA1DKhf0l9yOCfEvoNJNp10rTG5JFWeYaIiI3-ismQITIsR3u4akYy1PPjmNyF12vfcjlgbvXdGOcodyiZvKulnp2XNSQVIu-OHiwERumU5IISD9VRzY804Z1tKkRB7_PxpUvE7SOAKdOqmkvZLMn8ob1Fz8I562qiV8oezkVkSqTfqQbK2Vsqn3dYDd-IY0pjUhnw
-- http[s]://$FQDN:$PORT/send-money/$ADDRESS

type SendMoney = "send-money" :> Capture "destination_address" Text :> QueryParam' '[Optional] "api_key" Text :> RemoteHost :> Post '[JSON] SendMoneyReply
type Metrics = "metrics" :> Get '[PlainText] Text
--type SiteVerify = "recaptcha" :> "api" :> "siteverify" :> ReqBody '[FormUrlEncoded] SiteVerifyRequest :> Post '[JSON] SiteVerifyReply
type SiteVerifyMock = "videos" :> "private" :> "test.php" :> ReqBody '[FormUrlEncoded] SiteVerifyRequest :> Post '[JSON] SiteVerifyReply

-- faucet root dir
type RootDir = SendMoney :<|> Metrics
-- recaptcha root dir
type CaptchaRootDir = SiteVerifyMock

userAPI :: Proxy RootDir
userAPI = Proxy

recaptchaApi :: Proxy CaptchaRootDir
recaptchaApi = Proxy

siteVerifyMock :: SiteVerifyRequest -> ClientM SiteVerifyReply
siteVerifyMock = client recaptchaApi

doSiteVerify :: Text -> Text -> Maybe Text -> ClientM SiteVerifyReply
doSiteVerify secret token mRemoteIp = do
  res <- siteVerifyMock $ SiteVerifyRequest secret token mRemoteIp
  pure res

run :: IO ()
run = do
  --manager' <- newManager defaultManagerSettings
  manager' <- newTlsManagerWith tlsManagerSettings
  res <- runClientM (doSiteVerify "secret" "token" (Just "1.2.3.4")) (mkClientEnv manager' (BaseUrl Https "ext.earthtools.ca" 443 ""))
  print res

server :: IsShelleyBasedEra era =>
  CardanoEra era
  -> ShelleyBasedEra era
  -> FaucetState era
  -> Server RootDir
server era sbe faucetState = handleSendMoney era sbe faucetState :<|> handleMetrics faucetState

getRateLimits :: ApiKey -> FaucetConfigFile -> Maybe ApiKeyValue
getRateLimits Recaptcha FaucetConfigFile{fcfRecaptchaLimits} = Just fcfRecaptchaLimits
getRateLimits (ApiKey key) FaucetConfigFile{fcfApiKeys} = HM.lookup key fcfApiKeys

insertUsage :: TMVar (Map ApiKey (Map (Either AddressAny SockAddr) UTCTime)) -> ApiKey -> Either AddressAny SockAddr -> UTCTime -> STM ()
insertUsage tmvar apikey addr now = do
  mainMap <- takeTMVar tmvar
  let
    apiKeyMap :: Map (Either AddressAny SockAddr) UTCTime
    apiKeyMap = fromMaybe mempty (Map.lookup apikey mainMap)
    apiKeyMap' :: Map (Either AddressAny SockAddr) UTCTime
    apiKeyMap' = Map.insert addr now apiKeyMap
    mainMap' = Map.insert apikey apiKeyMap' mainMap
  putTMVar tmvar mainMap'

checkRateLimits :: IsCardanoEra era => AddressAny -> SockAddr -> ApiKey -> FaucetState era -> ExceptT FaucetWebError IO (Lovelace, [FaucetToken])
checkRateLimits addr remoteip apikey FaucetState{fsConfig,fsRateLimitState} = do
  now <- liftIO $ getCurrentTime
  let
    mRateLimits = getRateLimits apikey fsConfig
    recordUsage :: STM ()
    recordUsage = do
      insertUsage fsRateLimitState apikey (Left addr) now
      insertUsage fsRateLimitState apikey (Right remoteip) now
    -- Nothing means allow
    -- Just x means you can do it in x time
    checkRateLimitsInternal :: NominalDiffTime -> STM (Maybe NominalDiffTime)
    checkRateLimitsInternal interval = do
      mainMap <- readTMVar fsRateLimitState
      let
        apiKeyMap = fromMaybe mempty (Map.lookup apikey mainMap)
        getLastUsage :: Either AddressAny SockAddr -> Maybe UTCTime
        getLastUsage addr' = Map.lookup addr' apiKeyMap
        lastUsages :: [ Maybe UTCTime]
        lastUsages = [ getLastUsage (Left addr), getLastUsage (Right remoteip) ]
        compareTimes :: Maybe UTCTime -> Maybe UTCTime -> Maybe UTCTime
        compareTimes Nothing Nothing = Nothing
        compareTimes (Just a) Nothing = Just a
        compareTimes Nothing (Just b) = Just b
        compareTimes (Just a) (Just b) = Just (if a > b then a else b)
        lastUsage :: Maybe UTCTime
        lastUsage = Cardano.Prelude.foldl' compareTimes Nothing lastUsages
      disallow <- case lastUsage of
        Nothing -> do
          -- this addr has never been used on this api key
          pure Nothing
        Just lastUsed -> do
          let
            after = addUTCTime interval lastUsed
          pure $ if now > after then Nothing else (Just $ after `diffUTCTime` now)
      if (isNothing disallow) then recordUsage else pure ()
      pure disallow
  case mRateLimits of
    Nothing -> do
      -- api key not found in config
      left $ FaucetWebErrorRateLimit
    Just (ApiKeyValue lovelace interval tokens) -> do
      success <- liftIO $ atomically $ checkRateLimitsInternal interval
      case success of
        Nothing -> pure (lovelace,tokens)
        Just t -> left $ FaucetWebErrorRateLimitExeeeded t

checkRecaptcha :: Monad m => m Bool
checkRecaptcha = pure False

data MetricValue = MetricValueInt Integer | MetricValueFloat Float deriving Show

valToString :: MetricValue -> Text
valToString (MetricValueInt i) = show i
valToString (MetricValueFloat f) = show f

data Metric = Metric (Map Text MetricValue) Text MetricValue deriving Show

attributesToString :: Map Text MetricValue -> Text
attributesToString map' = if (Map.null map') then "" else wrapped
  where
    wrapped = "{" <> joinedAttrs <> "}"
    joinedAttrs = T.intercalate "," $ Map.elems $ Map.mapWithKey (\key val -> key <> "=\"" <> valToString val <> "\"") map'

toMetric :: Metric -> Text
toMetric (Metric attribs key val) = key <> (attributesToString attribs) <> " " <> valToString val

handleMetrics :: IsCardanoEra era => FaucetState era -> Servant.Handler Text
handleMetrics FaucetState{utxoTMVar,fsBucketSizes} = do
  liftIO $ do
    utxo <- atomically $ readTMVar utxoTMVar
    let
      (UtxoStats stats) = computeUtxoStats utxo
      isRequiredSize :: Lovelace -> [(Text, MetricValue)]
      isRequiredSize v = if (elem v fsBucketSizes) then [("is_valid",MetricValueInt 1)] else []
      toStats :: (FaucetValue, Integer) -> Metric
      toStats ((Ada l@(Lovelace v)), count) = Metric (Map.fromList $ [("lovelace",MetricValueInt v)] <> (isRequiredSize l)) "bucket_size" (MetricValueInt count)
      toStats (FaucetValueMultiAsset _, count) = Metric mempty "bucket_todo" (MetricValueInt count)
      metrics :: [Metric]
      metrics = map toStats $ Map.toList stats
      result = Cardano.Prelude.unlines $ Cardano.Prelude.map toMetric metrics
    pure result

handleSendMoney :: IsShelleyBasedEra era =>
  CardanoEra era
  -> ShelleyBasedEra era
  -> FaucetState era
  -> Text
  -> Maybe Text
  -> SockAddr
  -> Servant.Handler SendMoneyReply
handleSendMoney era sbe fs@FaucetState{network,utxoTMVar,skey,queue} addr mApiKey remoteip = do
  eResult <- liftIO $ runExceptT $ do
    addressAny <- parseAddress addr
    apiKey <- do
      case mApiKey of
        Just key -> pure $ ApiKey key
        Nothing -> do
          recaptcha <- checkRecaptcha
          case recaptcha of
            False -> do
              left FaucetWebErrorRateLimit
            True -> pure Recaptcha
    (lovelace,_tokens) <- checkRateLimits addressAny remoteip apiKey fs
    txinout@(txin,_) <- findUtxoOfSize utxoTMVar $ Ada lovelace
    putStr @Text "selected the following txin: "
    print txin
    eraInMode <- convertEra era
    -- instead of having to specify an output that is exactly equal to input-fees
    -- i specify no outputs, and set the change addr to the end-user
    unsignedTx <- txBuild sbe defaultCModeParams network txinout [] (TxOutChangeAddress addressAny)
    let
      txid :: TxId
      txid = getTxId unsignedTx
    putStrLn @Text $ "new txid: " <> (show txid)
    signedTx <- withExceptT (FaucetWebErrorTodo . renderShelleyTxCmdError) $ txSign network unsignedTx [skey]
    let
      prettyTx = friendlyTxBS era signedTx
    liftIO $ atomically $ writeTQueue queue (TxInMode signedTx eraInMode, prettyTx)
    return $ SendMoneyReplySuccess $ SendMoneySent txid txin
  case eResult of
    Right msg -> pure msg
    Left err -> pure $ SendMoneyError err
