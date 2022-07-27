{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}

module Cardano.CLI.Faucet.Types where

import Cardano.Api (AnyCardanoEra, IsCardanoEra, TxIn, TxOut, CtxUTxO, NetworkId, TxInMode, CardanoMode, TxId, FileError, Lovelace, AddressAny, NetworkId, AssetId(AssetId, AdaAssetId), Quantity)
import Cardano.CLI.Environment (EnvSocketError)
import Cardano.CLI.Shelley.Key
import Cardano.CLI.Shelley.Run.Address (SomeAddressVerificationKey)
import Cardano.CLI.Shelley.Run.Transaction (ShelleyTxCmdError, SomeWitness, renderShelleyTxCmdError)
import Cardano.Prelude
import Control.Concurrent.STM (TMVar, TQueue)
import Control.Monad.Trans.Except.Extra (left)
import Data.Aeson (ToJSON(..), object, (.=), Options(fieldLabelModifier), defaultOptions, camelTo2, genericToJSON, FromJSON(parseJSON), genericParseJSON, eitherDecodeFileStrict, Value, withObject, (.:))
import Data.HashMap.Strict qualified as HM
import Data.Time.Clock (UTCTime, NominalDiffTime)
import Network.Socket (SockAddr)
import Prelude (String, error)
import Web.Internal.FormUrlEncoded (ToForm(toForm), fromEntriesByKey)

data FaucetError = FaucetErrorTodo ShelleyTxCmdError
  | FaucetErrorSocketNotFound EnvSocketError
  | FaucetErrorLoadingKey (FileError InputDecodeError)
  | FaucetErrorParsingConfig String
  | FaucetErrorConfigFileNotSet
  deriving Generic

data FaucetWebError = FaucetWebErrorInvalidAddress Text Text
  | FaucetWebErrorRateLimit
  | FaucetWebErrorRateLimitExeeeded NominalDiffTime
  | FaucetWebErrorUtxoNotFound
  | FaucetWebErrorEraConversion
  | FaucetWebErrorSocketNotFound Text
  | FaucetWebErrorTodo Text
  | FaucetWebErrorFeatureMismatch AnyCardanoEra Text
  | FaucetWebErrorConsensusModeMismatchTxBalance Text AnyCardanoEra
  | FaucetWebErrorAcquireFailure Text
  | FaucetWebErrorEraMismatch Text
  | FaucetWebErrorAutoBalance Text
  deriving Generic

data ApiKey = Recaptcha | ApiKey Text deriving (Ord, Eq)

data IsCardanoEra era => FaucetState era = FaucetState
  { utxoTMVar :: TMVar (Map TxIn (TxOut CtxUTxO era))
  , network :: NetworkId
  , queue :: TQueue (TxInMode CardanoMode, ByteString)
  , skey :: SomeWitness
  , vkey :: SomeAddressVerificationKey
  , fsConfig :: FaucetConfigFile
  , fsRateLimitState :: TMVar (Map ApiKey (Map (Either AddressAny SockAddr) UTCTime))
  , fsBucketSizes :: [Lovelace]
  }

data SendMoneySent = SendMoneySent
  { txid :: TxId
  , txin :: TxIn
  }

data SendMoneyReply = SendMoneyReplySuccess SendMoneySent
  | SendMoneyError FaucetWebError

data ApiKeyValue = ApiKeyValue
  { akvLovelace :: Lovelace
  , akvRateLimit :: NominalDiffTime
  , akvTokens :: [FaucetToken]
  } deriving (Generic, Show)

data FaucetConfigFile = FaucetConfigFile
  { fcfSkeyPath :: FilePath
  , fcfApiKeys :: HM.HashMap Text ApiKeyValue
  , fcfRecaptchaLimits :: ApiKeyValue
  , fcfNetwork :: NetworkId
  } deriving (Generic, Show)

data FaucetValue = Ada Lovelace
  | FaucetValueMultiAsset [(AssetId, Quantity)] deriving (Show, Eq, Ord)

data UtxoStats = UtxoStats (Map FaucetValue Integer) deriving Show

data SiteVerifyRequest = SiteVerifyRequest
  { svrSecret :: Text
  , svrResponse :: Text
  , svrRemoteIP :: Maybe Text
  }

data SiteVerifyReply = SiteVerifyReply
  { svrSuccess :: Bool
  , svrChallengeTs :: Text
  , svrHostname :: Text
  , svrErrorCodes :: Maybe [Text]
  } deriving (Generic, Show)

instance ToJSON FaucetWebError where
  toJSON = genericToJSON defaultOptions

instance ToJSON SendMoneyReply where
  toJSON (SendMoneyReplySuccess (SendMoneySent{txid,txin})) = object [ "txid" .= txid, "txin" .= txin ]
  toJSON (SendMoneyError err) = object [ "error" .= err ]

tokenToValue :: FaucetToken -> Value
tokenToValue (FaucetToken (AssetId policyid token, q)) = object [ "policyid" .= policyid, "token" .= token, "quantity" .= q ]
tokenToValue (FaucetToken (AdaAssetId, q)) = object [ "lovelace" .= q ]

data FaucetToken = FaucetToken (AssetId, Quantity) deriving Show

instance FromJSON FaucetToken where
  parseJSON = withObject "FaucetToken" $ \v -> do
    policyid <- v .: "policy_id"
    quantity <- v .: "quantity"
    token <- v .: "token"
    pure $ FaucetToken (AssetId policyid token,quantity)

instance ToJSON ApiKeyValue where
  toJSON (ApiKeyValue l r t) = object [ "lovelace" .= l, "rate_limit" .= r, "tokens" .= map tokenToValue t ]

instance FromJSON ApiKeyValue where
  parseJSON = withObject "ApiKeyValue" $ \v -> do
    lovelace <- v .: "lovelace"
    ratelimit <- v .: "rate_limit"
    tokens <- v .: "tokens"
    pure $ ApiKeyValue lovelace ratelimit tokens

instance ToJSON FaucetConfigFile where
  toJSON = genericToJSON jsonOptions

instance FromJSON FaucetConfigFile where
  parseJSON = genericParseJSON jsonOptions

instance ToForm SiteVerifyRequest where
  toForm (SiteVerifyRequest secret token mRemoteIp) = fromEntriesByKey foo
    where
      foo :: [(Text, [Text])]
      foo = [ ("secret", [secret]), ("response", [token]) ] ++ maybe [] (\x -> [("remoteip",[x])]) mRemoteIp

instance FromJSON SiteVerifyReply where
  parseJSON = genericParseJSON jsonOptions

renderFaucetError :: FaucetError -> Text
renderFaucetError (FaucetErrorTodo err) = renderShelleyTxCmdError err
renderFaucetError (FaucetErrorSocketNotFound err) = show err
renderFaucetError (FaucetErrorLoadingKey err) = show err
renderFaucetError (FaucetErrorParsingConfig err) = show err
renderFaucetError FaucetErrorConfigFileNotSet = "$CONFIG_FILE not set"

-- TODO, find a better way to do this
jsonOptions :: Options
jsonOptions = defaultOptions { fieldLabelModifier = (camelTo2 '_') . stripPrefix }
  where
    stripPrefix :: String -> String
    stripPrefix (_:_:_:baseName) = baseName
    stripPrefix bad = error $ "bad fieldname: " ++ bad

parseConfig :: FilePath -> ExceptT FaucetError IO FaucetConfigFile
parseConfig path = do
  eResult <- liftIO $ eitherDecodeFileStrict path
  case eResult of
    Left err -> left $ FaucetErrorParsingConfig err
    Right res -> pure res

test :: IO ()
test = do
  eResult <- runExceptT $ do
    config <- parseConfig "/home/clever/iohk/cardano-world/sample-config.json"
    print config
  case eResult of
    Left err -> print $ renderFaucetError err
    Right msg -> print msg
