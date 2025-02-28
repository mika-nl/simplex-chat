{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Chat where

import Control.Applicative (optional, (<|>))
import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random (drgNew)
import qualified Data.Aeson as J
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64 as B64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isSpace)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.LocalTime (getCurrentTimeZone, getZonedTime)
import Data.Word (Word32)
import Simplex.Chat.Controller
import Simplex.Chat.Markdown
import Simplex.Chat.Messages
import Simplex.Chat.Options (ChatOpts (..), smpServersP)
import Simplex.Chat.Protocol
import Simplex.Chat.Store
import Simplex.Chat.Types
import Simplex.Chat.Util (ifM, safeDecodeUtf8, unlessM, whenM)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), defaultAgentConfig)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (base64P, parseAll)
import Simplex.Messaging.Protocol (ErrorType (..), MsgBody)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Util (tryError, (<$?>))
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (combine, splitExtensions, takeFileName)
import System.IO (Handle, IOMode (..), SeekMode (..), hFlush, openFile, stdout)
import Text.Read (readMaybe)
import UnliftIO.Async
import UnliftIO.Concurrent (forkIO, threadDelay)
import UnliftIO.Directory
import qualified UnliftIO.Exception as E
import UnliftIO.IO (hClose, hSeek, hTell)
import UnliftIO.STM

defaultChatConfig :: ChatConfig
defaultChatConfig =
  ChatConfig
    { agentConfig =
        defaultAgentConfig
          { tcpPort = undefined, -- agent does not listen to TCP
            initialSMPServers = undefined, -- filled in newChatController
            dbFile = undefined, -- filled in newChatController
            dbPoolSize = 1,
            yesToMigrations = False
          },
      dbPoolSize = 1,
      yesToMigrations = False,
      tbqSize = 64,
      fileChunkSize = 15780,
      subscriptionConcurrency = 16,
      subscriptionEvents = False,
      testView = False
    }

defaultSMPServers :: NonEmpty SMPServer
defaultSMPServers =
  L.fromList
    [ "smp://0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU=@smp8.simplex.im",
      "smp://SkIkI6EPd2D63F4xFKfHk7I1UGZVNn6k1QWZ5rcyr6w=@smp9.simplex.im",
      "smp://6iIcWT_dF2zN_w5xzZEY7HI2Prbh3ldP07YTyDexPjE=@smp10.simplex.im"
    ]

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

newChatController :: SQLiteStore -> Maybe User -> ChatConfig -> ChatOpts -> Maybe (Notification -> IO ()) -> IO ChatController
newChatController chatStore user cfg@ChatConfig {agentConfig = aCfg, tbqSize} ChatOpts {dbFilePrefix, smpServers, logConnections} sendToast = do
  let f = chatStoreFile dbFilePrefix
      config = cfg {subscriptionEvents = logConnections}
      sendNotification = fromMaybe (const $ pure ()) sendToast
  activeTo <- newTVarIO ActiveNone
  firstTime <- not <$> doesFileExist f
  currentUser <- newTVarIO user
  initialSMPServers <- resolveServers
  smpAgent <- getSMPAgentClient aCfg {dbFile = dbFilePrefix <> "_agent.db", initialSMPServers}
  agentAsync <- newTVarIO Nothing
  idsDrg <- newTVarIO =<< drgNew
  inputQ <- newTBQueueIO tbqSize
  outputQ <- newTBQueueIO tbqSize
  notifyQ <- newTBQueueIO tbqSize
  chatLock <- newTMVarIO ()
  sndFiles <- newTVarIO M.empty
  rcvFiles <- newTVarIO M.empty
  filesFolder <- newTVarIO Nothing
  pure ChatController {activeTo, firstTime, currentUser, smpAgent, agentAsync, chatStore, idsDrg, inputQ, outputQ, notifyQ, chatLock, sndFiles, rcvFiles, config, sendNotification, filesFolder}
  where
    resolveServers :: IO (NonEmpty SMPServer)
    resolveServers = case user of
      Nothing -> pure $ if null smpServers then defaultSMPServers else L.fromList smpServers
      Just usr -> do
        userSmpServers <- getSMPServers chatStore usr
        pure . fromMaybe defaultSMPServers . nonEmpty $ if null smpServers then userSmpServers else smpServers

runChatController :: (MonadUnliftIO m, MonadReader ChatController m) => User -> m ()
runChatController = race_ notificationSubscriber . agentSubscriber

startChatController :: (MonadUnliftIO m, MonadReader ChatController m) => User -> m (Async ())
startChatController user = do
  s <- asks agentAsync
  readTVarIO s >>= maybe (start s) pure
  where
    start s = do
      a <- async $ runChatController user
      atomically . writeTVar s $ Just a
      pure a

withLock :: MonadUnliftIO m => TMVar () -> m a -> m a
withLock lock =
  E.bracket_
    (void . atomically $ takeTMVar lock)
    (atomically $ putTMVar lock ())

execChatCommand :: (MonadUnliftIO m, MonadReader ChatController m) => ByteString -> m ChatResponse
execChatCommand s = case parseChatCommand s of
  Left e -> pure $ chatCmdError e
  Right cmd -> either CRChatCmdError id <$> runExceptT (processChatCommand cmd)

parseChatCommand :: ByteString -> Either String ChatCommand
parseChatCommand = parseAll chatCommandP . B.dropWhileEnd isSpace

toView :: ChatMonad m => ChatResponse -> m ()
toView event = do
  q <- asks outputQ
  atomically $ writeTBQueue q (Nothing, event)

processChatCommand :: forall m. ChatMonad m => ChatCommand -> m ChatResponse
processChatCommand = \case
  ShowActiveUser -> withUser' $ pure . CRActiveUser
  CreateActiveUser p -> do
    u <- asks currentUser
    whenM (isJust <$> readTVarIO u) $ throwChatError CEActiveUserExists
    user <- withStore $ \st -> createUser st p True
    atomically . writeTVar u $ Just user
    pure $ CRActiveUser user
  StartChat -> withUser' $ \user ->
    asks agentAsync >>= readTVarIO >>= \case
      Just _ -> pure CRChatRunning
      _ -> startChatController user $> CRChatStarted
  SetFilesFolder filesFolder' -> withUser $ \_ -> do
    createDirectoryIfMissing True filesFolder'
    ff <- asks filesFolder
    atomically . writeTVar ff $ Just filesFolder'
    pure CRCmdOk
  APIGetChats -> CRApiChats <$> withUser (\user -> withStore (`getChatPreviews` user))
  APIGetChat cType cId pagination -> withUser $ \user -> case cType of
    CTDirect -> CRApiChat . AChat SCTDirect <$> withStore (\st -> getDirectChat st user cId pagination)
    CTGroup -> CRApiChat . AChat SCTGroup <$> withStore (\st -> getGroupChat st user cId pagination)
    CTContactRequest -> pure $ chatCmdError "not implemented"
  APIGetChatItems _pagination -> pure $ chatCmdError "not implemented"
  APISendMessage cType chatId file_ quotedItemId_ mc -> withUser $ \user@User {userId} -> withChatLock $ case cType of
    CTDirect -> do
      ct@Contact {localDisplayName = c} <- withStore $ \st -> getContact st userId chatId
      (fileInvitation_, ciFile_) <- unzipMaybe <$> setupSndFileTransfer ct
      (msgContainer, quotedItem_) <- prepareMsg fileInvitation_
      msg <- sendDirectContactMessage ct (XMsgNew msgContainer)
      ci <- saveSndChatItem user (CDDirectSnd ct) msg (CISndMsgContent mc) ciFile_ quotedItem_
      setActive $ ActiveC c
      pure . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat ct) ci
      where
        setupSndFileTransfer :: Contact -> m (Maybe (FileInvitation, CIFile 'MDSnd))
        setupSndFileTransfer ct = case file_ of
          Nothing -> pure Nothing
          Just file -> do
            (fileSize, chSize) <- checkSndFile file
            (agentConnId, fileConnReq) <- withAgent (`createConnection` SCMInvitation)
            let fileName = takeFileName file
                fileInvitation = FileInvitation {fileName, fileSize, fileConnReq = Just fileConnReq}
            fileId <- withStore $ \st -> createSndFileTransfer st userId ct file fileInvitation agentConnId chSize
            let ciFile = CIFile {fileId, fileName, fileSize, filePath = Just file, fileStatus = CIFSSndStored}
            pure $ Just (fileInvitation, ciFile)
        prepareMsg :: Maybe FileInvitation -> m (MsgContainer, Maybe (CIQuote 'CTDirect))
        prepareMsg fileInvitation_ = case quotedItemId_ of
          Nothing -> pure (MCSimple (ExtMsgContent mc fileInvitation_), Nothing)
          Just quotedItemId -> do
            CChatItem _ ChatItem {meta = CIMeta {itemTs, itemSharedMsgId}, content = ciContent, formattedText} <-
              withStore $ \st -> getDirectChatItem st userId chatId quotedItemId
            (origQmc, qd, sent) <- quoteData ciContent
            let msgRef = MsgRef {msgId = itemSharedMsgId, sentAt = itemTs, sent, memberId = Nothing}
                qmc = quoteContent origQmc mc
                quotedItem = CIQuote {chatDir = qd, itemId = Just quotedItemId, sharedMsgId = itemSharedMsgId, sentAt = itemTs, content = qmc, formattedText}
            pure (MCQuote QuotedMsg {msgRef, content = qmc} (ExtMsgContent mc fileInvitation_), Just quotedItem)
          where
            quoteData :: CIContent d -> m (MsgContent, CIQDirection 'CTDirect, Bool)
            quoteData (CISndMsgContent qmc) = pure (qmc, CIQDirectSnd, True)
            quoteData (CIRcvMsgContent qmc) = pure (qmc, CIQDirectRcv, False)
            quoteData _ = throwChatError CEInvalidQuote
    CTGroup -> do
      Group gInfo@GroupInfo {membership, localDisplayName = gName} ms <- withStore $ \st -> getGroup st user chatId
      unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
      (fileInvitation_, ciFile_) <- unzipMaybe <$> setupSndFileTransfer gInfo
      (msgContainer, quotedItem_) <- prepareMsg fileInvitation_ membership
      msg <- sendGroupMessage gInfo ms (XMsgNew msgContainer)
      ci <- saveSndChatItem user (CDGroupSnd gInfo) msg (CISndMsgContent mc) ciFile_ quotedItem_
      setActive $ ActiveG gName
      pure . CRNewChatItem $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) ci
      where
        setupSndFileTransfer :: GroupInfo -> m (Maybe (FileInvitation, CIFile 'MDSnd))
        setupSndFileTransfer gInfo = case file_ of
          Nothing -> pure Nothing
          Just file -> do
            (fileSize, chSize) <- checkSndFile file
            let fileName = takeFileName file
                fileInvitation = FileInvitation {fileName, fileSize, fileConnReq = Nothing}
            fileId <- withStore $ \st -> createSndGroupFileTransferV2 st userId gInfo file fileInvitation chSize
            let ciFile = CIFile {fileId, fileName, fileSize, filePath = Just file, fileStatus = CIFSSndStored}
            pure $ Just (fileInvitation, ciFile)
        prepareMsg :: Maybe FileInvitation -> GroupMember -> m (MsgContainer, Maybe (CIQuote 'CTGroup))
        prepareMsg fileInvitation_ membership = case quotedItemId_ of
          Nothing -> pure (MCSimple (ExtMsgContent mc fileInvitation_), Nothing)
          Just quotedItemId -> do
            CChatItem _ ChatItem {chatDir, meta = CIMeta {itemTs, itemSharedMsgId}, content = ciContent, formattedText} <-
              withStore $ \st -> getGroupChatItem st user chatId quotedItemId
            (origQmc, qd, sent, GroupMember {memberId}) <- quoteData ciContent chatDir membership
            let msgRef = MsgRef {msgId = itemSharedMsgId, sentAt = itemTs, sent, memberId = Just memberId}
                qmc = quoteContent origQmc mc
                quotedItem = CIQuote {chatDir = qd, itemId = Just quotedItemId, sharedMsgId = itemSharedMsgId, sentAt = itemTs, content = qmc, formattedText}
            pure (MCQuote QuotedMsg {msgRef, content = qmc} (ExtMsgContent mc fileInvitation_), Just quotedItem)
          where
            quoteData :: CIContent d -> CIDirection 'CTGroup d -> GroupMember -> m (MsgContent, CIQDirection 'CTGroup, Bool, GroupMember)
            quoteData (CISndMsgContent qmc) CIGroupSnd membership' = pure (qmc, CIQGroupSnd, True, membership')
            quoteData (CIRcvMsgContent qmc) (CIGroupRcv m) _ = pure (qmc, CIQGroupRcv $ Just m, False, m)
            quoteData _ _ _ = throwChatError CEInvalidQuote
    CTContactRequest -> pure $ chatCmdError "not supported"
    where
      quoteContent qmc = \case
        MCText _ -> qmc
        _ -> MCText $ msgContentText qmc
      unzipMaybe :: Maybe (a, b) -> (Maybe a, Maybe b)
      unzipMaybe t = (fst <$> t, snd <$> t)
  -- TODO discontinue
  APISendMessageQuote cType chatId quotedItemId mc ->
    processChatCommand $ APISendMessage cType chatId Nothing (Just quotedItemId) mc
  APIUpdateChatItem cType chatId itemId mc -> withUser $ \user@User {userId} -> withChatLock $ case cType of
    CTDirect -> do
      (ct@Contact {contactId, localDisplayName = c}, ci) <- withStore $ \st -> (,) <$> getContact st userId chatId <*> getDirectChatItem st userId chatId itemId
      case ci of
        CChatItem SMDSnd ChatItem {meta = CIMeta {itemSharedMsgId}, content = ciContent} -> do
          case (ciContent, itemSharedMsgId) of
            (CISndMsgContent _, Just itemSharedMId) -> do
              SndMessage {msgId} <- sendDirectContactMessage ct (XMsgUpdate itemSharedMId mc)
              updCi <- withStore $ \st -> updateDirectChatItem st userId contactId itemId (CISndMsgContent mc) msgId
              setActive $ ActiveC c
              pure . CRChatItemUpdated $ AChatItem SCTDirect SMDSnd (DirectChat ct) updCi
            _ -> throwChatError CEInvalidChatItemUpdate
        CChatItem SMDRcv _ -> throwChatError CEInvalidChatItemUpdate
    CTGroup -> do
      Group gInfo@GroupInfo {groupId, localDisplayName = gName, membership} ms <- withStore $ \st -> getGroup st user chatId
      unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
      ci <- withStore $ \st -> getGroupChatItem st user chatId itemId
      case ci of
        CChatItem SMDSnd ChatItem {meta = CIMeta {itemSharedMsgId}, content = ciContent} -> do
          case (ciContent, itemSharedMsgId) of
            (CISndMsgContent _, Just itemSharedMId) -> do
              SndMessage {msgId} <- sendGroupMessage gInfo ms (XMsgUpdate itemSharedMId mc)
              updCi <- withStore $ \st -> updateGroupChatItem st user groupId itemId (CISndMsgContent mc) msgId
              setActive $ ActiveG gName
              pure . CRChatItemUpdated $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) updCi
            _ -> throwChatError CEInvalidChatItemUpdate
        CChatItem SMDRcv _ -> throwChatError CEInvalidChatItemUpdate
    CTContactRequest -> pure $ chatCmdError "not supported"
  APIDeleteChatItem cType chatId itemId mode -> withUser $ \user@User {userId} -> withChatLock $ case cType of
    CTDirect -> do
      (ct@Contact {localDisplayName = c}, CChatItem msgDir deletedItem@ChatItem {meta = CIMeta {itemSharedMsgId}, file}) <- withStore $ \st -> (,) <$> getContact st userId chatId <*> getDirectChatItem st userId chatId itemId
      case (mode, msgDir, itemSharedMsgId) of
        (CIDMInternal, _, _) -> do
          deleteFile userId file
          toCi <- withStore $ \st -> deleteDirectChatItemInternal st userId ct itemId
          pure $ CRChatItemDeleted (AChatItem SCTDirect msgDir (DirectChat ct) deletedItem) toCi
        (CIDMBroadcast, SMDSnd, Just itemSharedMId) -> do
          SndMessage {msgId} <- sendDirectContactMessage ct (XMsgDel itemSharedMId)
          deleteFile userId file
          toCi <- withStore $ \st -> deleteDirectChatItemSndBroadcast st userId ct itemId msgId
          setActive $ ActiveC c
          pure $ CRChatItemDeleted (AChatItem SCTDirect msgDir (DirectChat ct) deletedItem) toCi
        (CIDMBroadcast, _, _) -> throwChatError CEInvalidChatItemDelete
    CTGroup -> do
      Group gInfo@GroupInfo {localDisplayName = gName, membership} ms <- withStore $ \st -> getGroup st user chatId
      unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
      CChatItem msgDir deletedItem@ChatItem {meta = CIMeta {itemSharedMsgId}, file} <- withStore $ \st -> getGroupChatItem st user chatId itemId
      case (mode, msgDir, itemSharedMsgId) of
        (CIDMInternal, _, _) -> do
          deleteFile userId file
          toCi <- withStore $ \st -> deleteGroupChatItemInternal st user gInfo itemId
          pure $ CRChatItemDeleted (AChatItem SCTGroup msgDir (GroupChat gInfo) deletedItem) toCi
        (CIDMBroadcast, SMDSnd, Just itemSharedMId) -> do
          SndMessage {msgId} <- sendGroupMessage gInfo ms (XMsgDel itemSharedMId)
          deleteFile userId file
          toCi <- withStore $ \st -> deleteGroupChatItemSndBroadcast st user gInfo itemId msgId
          setActive $ ActiveG gName
          pure $ CRChatItemDeleted (AChatItem SCTGroup msgDir (GroupChat gInfo) deletedItem) toCi
        (CIDMBroadcast, _, _) -> throwChatError CEInvalidChatItemDelete
    CTContactRequest -> pure $ chatCmdError "not supported"
    where
      deleteFile :: MsgDirectionI d => UserId -> Maybe (CIFile d) -> m ()
      deleteFile userId file =
        forM_ file $ \CIFile {fileId, filePath, fileStatus} -> do
          cancelFiles userId [(fileId, AFS msgDirection fileStatus)]
          withFilesFolder $ \filesFolder ->
            deleteFiles filesFolder [filePath]
  APIChatRead cType chatId fromToIds -> withChatLock $ case cType of
    CTDirect -> withStore (\st -> updateDirectChatItemsRead st chatId fromToIds) $> CRCmdOk
    CTGroup -> withStore (\st -> updateGroupChatItemsRead st chatId fromToIds) $> CRCmdOk
    CTContactRequest -> pure $ chatCmdError "not supported"
  APIDeleteChat cType chatId -> withUser $ \User {userId} -> case cType of
    CTDirect -> do
      ct@Contact {localDisplayName} <- withStore $ \st -> getContact st userId chatId
      withStore (\st -> getContactGroupNames st userId ct) >>= \case
        [] -> do
          files <- withStore $ \st -> getContactFiles st userId ct
          conns <- withStore $ \st -> getContactConnections st userId ct
          withChatLock . procCmd $ do
            cancelFiles userId (map (\(fId, fStatus, _) -> (fId, fStatus)) files)
            withFilesFolder $ \filesFolder -> do
              deleteFiles filesFolder (map (\(_, _, fPath) -> fPath) files)
            withAgent $ \a -> forM_ conns $ \conn ->
              deleteConnection a (aConnId conn) `catchError` \(_ :: AgentErrorType) -> pure ()
            withStore $ \st -> deleteContact st userId ct
            unsetActive $ ActiveC localDisplayName
            pure $ CRContactDeleted ct
        gs -> throwChatError $ CEContactGroups ct gs
    CTGroup -> pure $ chatCmdError "not implemented"
    CTContactRequest -> pure $ chatCmdError "not supported"
  APIAcceptContact connReqId -> withUser $ \user@User {userId} -> withChatLock $ do
    cReq <- withStore $ \st -> getContactRequest st userId connReqId
    procCmd $ CRAcceptingContactRequest <$> acceptContactRequest user cReq
  APIRejectContact connReqId -> withUser $ \User {userId} -> withChatLock $ do
    cReq@UserContactRequest {agentContactConnId = AgentConnId connId, agentInvitationId = AgentInvId invId} <-
      withStore $ \st ->
        getContactRequest st userId connReqId
          `E.finally` deleteContactRequest st userId connReqId
    withAgent $ \a -> rejectContact a connId invId
    pure $ CRContactRequestRejected cReq
  APIUpdateProfile profile -> withUser (`updateProfile` profile)
  APIParseMarkdown text -> pure . CRApiParsedMarkdown $ parseMaybeMarkdownList text
  GetUserSMPServers -> CRUserSMPServers <$> withUser (\user -> withStore (`getSMPServers` user))
  SetUserSMPServers smpServers -> withUser $ \user -> withChatLock $ do
    withStore $ \st -> overwriteSMPServers st user smpServers
    withAgent $ \a -> setSMPServers a (fromMaybe defaultSMPServers (nonEmpty smpServers))
    pure CRCmdOk
  ChatHelp section -> pure $ CRChatHelp section
  Welcome -> withUser $ pure . CRWelcome
  AddContact -> withUser $ \User {userId} -> withChatLock . procCmd $ do
    (connId, cReq) <- withAgent (`createConnection` SCMInvitation)
    withStore $ \st -> createDirectConnection st userId connId
    pure $ CRInvitation cReq
  Connect (Just (ACR SCMInvitation cReq)) -> withUser $ \User {userId, profile} -> withChatLock . procCmd $ do
    connId <- withAgent $ \a -> joinConnection a cReq . directMessage $ XInfo profile
    withStore $ \st -> createDirectConnection st userId connId
    pure CRSentConfirmation
  Connect (Just (ACR SCMContact cReq)) -> withUser $ \User {userId, profile} ->
    connectViaContact userId cReq profile
  Connect Nothing -> throwChatError CEInvalidConnReq
  ConnectSimplex -> withUser $ \User {userId, profile} ->
    connectViaContact userId adminContactReq profile
  DeleteContact cName -> withUser $ \User {userId} -> do
    contactId <- withStore $ \st -> getContactIdByName st userId cName
    processChatCommand $ APIDeleteChat CTDirect contactId
  ListContacts -> withUser $ \user -> CRContactsList <$> withStore (`getUserContacts` user)
  CreateMyAddress -> withUser $ \User {userId} -> withChatLock . procCmd $ do
    (connId, cReq) <- withAgent (`createConnection` SCMContact)
    withStore $ \st -> createUserContactLink st userId connId cReq
    pure $ CRUserContactLinkCreated cReq
  DeleteMyAddress -> withUser $ \User {userId} -> withChatLock $ do
    conns <- withStore $ \st -> getUserContactLinkConnections st userId
    procCmd $ do
      withAgent $ \a -> forM_ conns $ \conn ->
        deleteConnection a (aConnId conn) `catchError` \(_ :: AgentErrorType) -> pure ()
      withStore $ \st -> deleteUserContactLink st userId
      pure CRUserContactLinkDeleted
  ShowMyAddress -> withUser $ \User {userId} ->
    uncurry CRUserContactLink <$> withStore (`getUserContactLink` userId)
  AddressAutoAccept onOff -> withUser $ \User {userId} -> do
    uncurry CRUserContactLinkUpdated <$> withStore (\st -> updateUserContactLinkAutoAccept st userId onOff)
  AcceptContact cName -> withUser $ \User {userId} -> do
    connReqId <- withStore $ \st -> getContactRequestIdByName st userId cName
    processChatCommand $ APIAcceptContact connReqId
  RejectContact cName -> withUser $ \User {userId} -> do
    connReqId <- withStore $ \st -> getContactRequestIdByName st userId cName
    processChatCommand $ APIRejectContact connReqId
  SendMessage cName msg -> withUser $ \User {userId} -> do
    contactId <- withStore $ \st -> getContactIdByName st userId cName
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APISendMessage CTDirect contactId Nothing Nothing mc
  SendMessageBroadcast msg -> withUser $ \user -> do
    contacts <- withStore (`getUserContacts` user)
    withChatLock . procCmd $ do
      let mc = MCText $ safeDecodeUtf8 msg
          cts = filter isReady contacts
      forM_ cts $ \ct ->
        void
          ( do
              sndMsg <- sendDirectContactMessage ct (XMsgNew $ MCSimple (ExtMsgContent mc Nothing))
              saveSndChatItem user (CDDirectSnd ct) sndMsg (CISndMsgContent mc) Nothing Nothing
          )
          `catchError` (toView . CRChatError)
      CRBroadcastSent mc (length cts) <$> liftIO getZonedTime
  SendMessageQuote cName (AMsgDirection msgDir) quotedMsg msg -> withUser $ \User {userId} -> do
    contactId <- withStore $ \st -> getContactIdByName st userId cName
    quotedItemId <- withStore $ \st -> getDirectChatItemIdByText st userId contactId msgDir (safeDecodeUtf8 quotedMsg)
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APISendMessage CTDirect contactId Nothing (Just quotedItemId) mc
  DeleteMessage cName deletedMsg -> withUser $ \User {userId} -> do
    contactId <- withStore $ \st -> getContactIdByName st userId cName
    deletedItemId <- withStore $ \st -> getDirectChatItemIdByText st userId contactId SMDSnd (safeDecodeUtf8 deletedMsg)
    processChatCommand $ APIDeleteChatItem CTDirect contactId deletedItemId CIDMBroadcast
  EditMessage cName editedMsg msg -> withUser $ \User {userId} -> do
    contactId <- withStore $ \st -> getContactIdByName st userId cName
    editedItemId <- withStore $ \st -> getDirectChatItemIdByText st userId contactId SMDSnd (safeDecodeUtf8 editedMsg)
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APIUpdateChatItem CTDirect contactId editedItemId mc
  NewGroup gProfile -> withUser $ \user -> do
    gVar <- asks idsDrg
    CRGroupCreated <$> withStore (\st -> createNewGroup st gVar user gProfile)
  AddMember gName cName memRole -> withUser $ \user@User {userId} -> withChatLock $ do
    -- TODO for large groups: no need to load all members to determine if contact is a member
    (group, contact) <- withStore $ \st -> (,) <$> getGroupByName st user gName <*> getContactByName st userId cName
    let Group gInfo@GroupInfo {groupId, groupProfile, membership} members = group
        GroupMember {memberRole = userRole, memberId = userMemberId} = membership
    when (userRole < GRAdmin || userRole < memRole) $ throwChatError CEGroupUserRole
    when (memberStatus membership == GSMemInvited) $ throwChatError (CEGroupNotJoined gInfo)
    unless (memberActive membership) $ throwChatError CEGroupMemberNotActive
    let sendInvitation memberId cReq = do
          void . sendDirectContactMessage contact $
            XGrpInv $ GroupInvitation (MemberIdRole userMemberId userRole) (MemberIdRole memberId memRole) cReq groupProfile
          setActive $ ActiveG gName
          pure $ CRSentGroupInvitation gInfo contact
    case contactMember contact members of
      Nothing -> do
        gVar <- asks idsDrg
        (agentConnId, cReq) <- withAgent (`createConnection` SCMInvitation)
        GroupMember {memberId} <- withStore $ \st -> createContactMember st gVar user groupId contact memRole agentConnId cReq
        sendInvitation memberId cReq
      Just GroupMember {groupMemberId, memberId, memberStatus}
        | memberStatus == GSMemInvited ->
          withStore (\st -> getMemberInvitation st user groupMemberId) >>= \case
            Just cReq -> sendInvitation memberId cReq
            Nothing -> throwChatError $ CEGroupCantResendInvitation gInfo cName
        | otherwise -> throwChatError $ CEGroupDuplicateMember cName
  JoinGroup gName -> withUser $ \user@User {userId} -> do
    ReceivedGroupInvitation {fromMember, connRequest, groupInfo = g} <- withStore $ \st -> getGroupInvitation st user gName
    withChatLock . procCmd $ do
      agentConnId <- withAgent $ \a -> joinConnection a connRequest . directMessage . XGrpAcpt $ memberId (membership g :: GroupMember)
      withStore $ \st -> do
        createMemberConnection st userId fromMember agentConnId
        updateGroupMemberStatus st userId fromMember GSMemAccepted
        updateGroupMemberStatus st userId (membership g) GSMemAccepted
      pure $ CRUserAcceptedGroupSent g
  MemberRole _gName _cName _mRole -> throwChatError $ CECommandError "unsupported"
  RemoveMember gName cName -> withUser $ \user@User {userId} -> do
    Group gInfo@GroupInfo {membership} members <- withStore $ \st -> getGroupByName st user gName
    case find ((== cName) . (localDisplayName :: GroupMember -> ContactName)) members of
      Nothing -> throwChatError $ CEGroupMemberNotFound cName
      Just m@GroupMember {memberId = mId, memberRole = mRole, memberStatus = mStatus} -> do
        let userRole = memberRole (membership :: GroupMember)
        when (userRole < GRAdmin || userRole < mRole) $ throwChatError CEGroupUserRole
        withChatLock . procCmd $ do
          when (mStatus /= GSMemInvited) . void . sendGroupMessage gInfo members $ XGrpMemDel mId
          deleteMemberConnection m
          withStore $ \st -> updateGroupMemberStatus st userId m GSMemRemoved
          pure $ CRUserDeletedMember gInfo m
  LeaveGroup gName -> withUser $ \user@User {userId} -> do
    Group gInfo@GroupInfo {membership} members <- withStore $ \st -> getGroupByName st user gName
    withChatLock . procCmd $ do
      void $ sendGroupMessage gInfo members XGrpLeave
      mapM_ deleteMemberConnection members
      withStore $ \st -> updateGroupMemberStatus st userId membership GSMemLeft
      pure $ CRLeftMemberUser gInfo
  DeleteGroup gName -> withUser $ \user -> do
    g@(Group gInfo@GroupInfo {membership} members) <- withStore $ \st -> getGroupByName st user gName
    let s = memberStatus membership
        canDelete =
          memberRole (membership :: GroupMember) == GROwner
            || (s == GSMemRemoved || s == GSMemLeft || s == GSMemGroupDeleted || s == GSMemInvited)
    unless canDelete $ throwChatError CEGroupUserRole
    withChatLock . procCmd $ do
      when (memberActive membership) . void $ sendGroupMessage gInfo members XGrpDel
      mapM_ deleteMemberConnection members
      withStore $ \st -> deleteGroup st user g
      pure $ CRGroupDeletedUser gInfo
  ListMembers gName -> CRGroupMembers <$> withUser (\user -> withStore (\st -> getGroupByName st user gName))
  ListGroups -> CRGroupsList <$> withUser (\user -> withStore (`getUserGroupDetails` user))
  SendGroupMessage gName msg -> withUser $ \user -> do
    groupId <- withStore $ \st -> getGroupIdByName st user gName
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APISendMessage CTGroup groupId Nothing Nothing mc
  SendGroupMessageQuote gName cName quotedMsg msg -> withUser $ \user -> do
    groupId <- withStore $ \st -> getGroupIdByName st user gName
    quotedItemId <- withStore $ \st -> getGroupChatItemIdByText st user groupId cName (safeDecodeUtf8 quotedMsg)
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APISendMessage CTGroup groupId Nothing (Just quotedItemId) mc
  DeleteGroupMessage gName deletedMsg -> withUser $ \user@User {localDisplayName} -> do
    groupId <- withStore $ \st -> getGroupIdByName st user gName
    deletedItemId <- withStore $ \st -> getGroupChatItemIdByText st user groupId (Just localDisplayName) (safeDecodeUtf8 deletedMsg)
    processChatCommand $ APIDeleteChatItem CTGroup groupId deletedItemId CIDMBroadcast
  EditGroupMessage gName editedMsg msg -> withUser $ \user@User {localDisplayName} -> do
    groupId <- withStore $ \st -> getGroupIdByName st user gName
    editedItemId <- withStore $ \st -> getGroupChatItemIdByText st user groupId (Just localDisplayName) (safeDecodeUtf8 editedMsg)
    let mc = MCText $ safeDecodeUtf8 msg
    processChatCommand $ APIUpdateChatItem CTGroup groupId editedItemId mc
  -- old file protocol
  -- SendFile cName f -> withUser $ \User {userId} -> do
  --   contactId <- withStore $ \st -> getContactIdByName st userId cName
  --   processChatCommand $ APISendMessage CTDirect contactId (Just f) Nothing (MCText "")
  -- TODO replace with code above when switching from XFile
  SendFile cName f -> withUser $ \user@User {userId} -> withChatLock $ do
    (fileSize, chSize) <- checkSndFile f
    contact <- withStore $ \st -> getContactByName st userId cName
    (agentConnId, fileConnReq) <- withAgent (`createConnection` SCMInvitation)
    let fileName = takeFileName f
        fileInv = FileInvitation {fileName = takeFileName f, fileSize, fileConnReq = Just fileConnReq}
    fileId <- withStore $ \st ->
      createSndFileTransfer st userId contact f fileInv agentConnId chSize
    msg <- sendDirectContactMessage contact (XFile fileInv)
    let ciFile = CIFile {fileId, fileName, fileSize, filePath = Just f, fileStatus = CIFSSndStored}
    ci <- saveSndChatItem user (CDDirectSnd contact) msg (CISndMsgContent $ MCText "") (Just ciFile) Nothing
    withStore $ \st -> updateFileTransferChatItemId st fileId $ chatItemId' ci
    setActive $ ActiveC cName
    pure . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat contact) ci
  -- new file protocol (not used for direct files)
  SendFileInv cName f -> withUser $ \user@User {userId} -> withChatLock $ do
    ct <- withStore $ \st -> getContactByName st userId cName
    (fileSize, chSize) <- checkSndFile f
    let fileName = takeFileName f
        fileInvitation = FileInvitation {fileName, fileSize, fileConnReq = Nothing}
    fileId <- withStore $ \st -> createSndFileTransferV2 st userId ct f fileInvitation chSize
    let mc = MCText ""
        ciFile = Just $ CIFile {fileId, fileName, fileSize, filePath = Just f, fileStatus = CIFSSndStored}
    msg <- sendDirectContactMessage ct (XMsgNew (MCSimple (ExtMsgContent mc (Just fileInvitation))))
    ci <- saveSndChatItem user (CDDirectSnd ct) msg (CISndMsgContent mc) ciFile Nothing
    setActive $ ActiveC cName
    pure . CRNewChatItem $ AChatItem SCTDirect SMDSnd (DirectChat ct) ci
  -- old file protocol
  -- TODO discontinue
  SendGroupFile gName f -> withUser $ \user@User {userId} -> withChatLock $ do
    Group gInfo@GroupInfo {groupId, membership} members <- withStore $ \st -> getGroupByName st user gName
    unless (memberActive membership) $ throwChatError CEGroupMemberUserRemoved
    (fileSize, chSize) <- checkSndFile f
    let fileName = takeFileName f
    ms <- forM (filter memberActive members) $ \m -> do
      (connId, fileConnReq) <- withAgent (`createConnection` SCMInvitation)
      pure (m, connId, FileInvitation {fileName, fileSize, fileConnReq = Just fileConnReq})
    fileId <- withStore $ \st -> createSndGroupFileTransfer st userId gInfo ms f fileSize chSize
    forM_ ms $ \(m, _, fileInvitation) ->
      traverse (\conn -> sendDirectMessage conn (XFile fileInvitation) (GroupId groupId)) $ memberConn m
    setActive $ ActiveG gName
    -- this is a hack as we have multiple direct messages instead of one per group
    let msg = SndMessage {msgId = 0, sharedMsgId = SharedMsgId "", msgBody = ""}
        ciFile = Just $ CIFile {fileId, fileName, fileSize, filePath = Just f, fileStatus = CIFSSndStored}
    ci <- saveSndChatItem user (CDGroupSnd gInfo) msg (CISndMsgContent $ MCText "") ciFile Nothing
    pure . CRNewChatItem $ AChatItem SCTGroup SMDSnd (GroupChat gInfo) ci
  -- new file protocol
  SendGroupFileInv gName f -> withUser $ \user -> do
    groupId <- withStore $ \st -> getGroupIdByName st user gName
    processChatCommand $ APISendMessage CTGroup groupId (Just f) Nothing (MCText "")
  ReceiveFile fileId filePath_ -> withUser $ \user@User {userId} ->
    withChatLock . procCmd $ do
      ft <- withStore $ \st -> getRcvFileTransfer st userId fileId
      (CRRcvFileAccepted ft <$> acceptFileReceive user ft filePath_) `catchError` processError ft
    where
      processError ft = \case
        ChatErrorAgent (SMP SMP.AUTH) -> pure $ CRRcvFileAcceptedSndCancelled ft
        ChatErrorAgent (CONN DUPLICATE) -> pure $ CRRcvFileAcceptedSndCancelled ft
        e -> throwError e
  CancelFile fileId -> withUser $ \User {userId} -> do
    ft <- withStore (\st -> getFileTransfer st userId fileId)
    withChatLock . procCmd $ cancelFile userId fileId ft
  FileStatus fileId ->
    CRFileTransferStatus <$> withUser (\User {userId} -> withStore $ \st -> getFileTransferProgress st userId fileId)
  ShowProfile -> withUser $ \User {profile} -> pure $ CRUserProfile profile
  UpdateProfile displayName fullName -> withUser $ \user@User {profile} -> do
    let p = (profile :: Profile) {displayName = displayName, fullName = fullName}
    updateProfile user p
  UpdateProfileImage image -> withUser $ \user@User {profile} -> do
    let p = (profile :: Profile) {image}
    updateProfile user p
  QuitChat -> liftIO exitSuccess
  ShowVersion -> pure $ CRVersionInfo versionNumber
  where
    withChatLock action = do
      ChatController {chatLock = l, smpAgent = a} <- ask
      withAgentLock a . withLock l $ action
    -- below code would make command responses asynchronous where they can be slow
    -- in View.hs `r'` should be defined as `id` in this case
    -- procCmd :: m ChatResponse -> m ChatResponse
    -- procCmd action = do
    --   ChatController {chatLock = l, smpAgent = a, outputQ = q, idsDrg = gVar} <- ask
    --   corrId <- liftIO $ SMP.CorrId <$> randomBytes gVar 8
    --   void . forkIO $
    --     withAgentLock a . withLock l $
    --       (atomically . writeTBQueue q) . (Just corrId,) =<< (action `catchError` (pure . CRChatError))
    --   pure $ CRCmdAccepted corrId
    -- use function below to make commands "synchronous"
    procCmd :: m ChatResponse -> m ChatResponse
    procCmd = id
    connectViaContact :: UserId -> ConnectionRequestUri 'CMContact -> Profile -> m ChatResponse
    connectViaContact userId cReq profile = withChatLock $ do
      let cReqHash = ConnReqUriHash . C.sha256Hash $ strEncode cReq
      withStore (\st -> getConnReqContactXContactId st userId cReqHash) >>= \case
        (Just contact, _) -> pure $ CRContactAlreadyExists contact
        (_, xContactId_) -> procCmd $ do
          let randomXContactId = XContactId <$> (asks idsDrg >>= liftIO . (`randomBytes` 16))
          xContactId <- maybe randomXContactId pure xContactId_
          connId <- withAgent $ \a -> joinConnection a cReq $ directMessage (XContact profile $ Just xContactId)
          withStore $ \st -> createConnReqConnection st userId connId cReqHash xContactId
          pure CRSentInvitation
    contactMember :: Contact -> [GroupMember] -> Maybe GroupMember
    contactMember Contact {contactId} =
      find $ \GroupMember {memberContactId = cId, memberStatus = s} ->
        cId == Just contactId && s /= GSMemRemoved && s /= GSMemLeft
    checkSndFile :: FilePath -> m (Integer, Integer)
    checkSndFile f = do
      fsFilePath <- toFSFilePath f
      unlessM (doesFileExist fsFilePath) . throwChatError $ CEFileNotFound f
      (,) <$> getFileSize fsFilePath <*> asks (fileChunkSize . config)
    updateProfile :: User -> Profile -> m ChatResponse
    updateProfile user@User {profile = p} p'@Profile {displayName}
      | p' == p = pure CRUserProfileNoChange
      | otherwise = do
        withStore $ \st -> updateUserProfile st user p'
        let user' = (user :: User) {localDisplayName = displayName, profile = p'}
        asks currentUser >>= atomically . (`writeTVar` Just user')
        contacts <- filter isReady <$> withStore (`getUserContacts` user)
        withChatLock . procCmd $ do
          forM_ contacts $ \ct ->
            void (sendDirectContactMessage ct $ XInfo p') `catchError` (toView . CRChatError)
          pure $ CRUserProfileUpdated p p'
    isReady :: Contact -> Bool
    isReady ct =
      let s = connStatus $ activeConn (ct :: Contact)
       in s == ConnReady || s == ConnSndReady
    -- perform an action only if filesFolder is set (i.e. on mobile devices)
    withFilesFolder :: (FilePath -> m ()) -> m ()
    withFilesFolder action = asks filesFolder >>= readTVarIO >>= mapM_ action
    deleteFiles :: FilePath -> [Maybe FilePath] -> m ()
    deleteFiles filesFolder filePaths =
      forM_ filePaths $ \filePath_ ->
        forM_ filePath_ $ \filePath -> do
          let fsFilePath = filesFolder <> "/" <> filePath
          removeFile fsFilePath `E.catch` \(_ :: E.SomeException) ->
            removePathForcibly fsFilePath `E.catch` \(_ :: E.SomeException) -> pure ()
    cancelFiles :: UserId -> [(Int64, ACIFileStatus)] -> m ()
    cancelFiles userId files =
      forM_ files $ \(fileId, status) -> do
        case status of
          AFS _ CIFSSndStored -> cancelById fileId
          AFS _ CIFSRcvInvitation -> cancelById fileId
          AFS _ CIFSRcvTransfer -> cancelById fileId
          _ -> pure ()
      where
        cancelById fileId = do
          ft <- withStore (\st -> getFileTransfer st userId fileId)
          void $ cancelFile userId fileId ft
    cancelFile :: UserId -> Int64 -> FileTransfer -> m ChatResponse
    cancelFile userId fileId ft =
      case ft of
        FTSnd ftm fts -> do
          cancelFileTransfer CIFSSndCancelled
          forM_ fts $ \ft' -> cancelSndFileTransfer ft'
          pure $ CRSndGroupFileCancelled ftm fts
        FTRcv ftr -> do
          cancelFileTransfer CIFSRcvCancelled
          cancelRcvFileTransfer ftr
          pure $ CRRcvFileCancelled ftr
      where
        cancelFileTransfer :: MsgDirectionI d => CIFileStatus d -> m ()
        cancelFileTransfer ciFileStatus =
          unless (fileTransferCancelled ft) $
            withStore $ \st -> do
              updateFileCancelled st userId fileId
              updateCIFileStatus st userId fileId ciFileStatus

-- mobile clients use file paths relative to app directory (e.g. for the reason ios app directory changes on updates),
-- so we have to differentiate between the file path stored in db and communicated with frontend, and the file path
-- used during file transfer for actual operations with file system
toFSFilePath :: ChatMonad m => FilePath -> m FilePath
toFSFilePath f =
  maybe f (<> "/" <> f) <$> (readTVarIO =<< asks filesFolder)

acceptFileReceive :: forall m. ChatMonad m => User -> RcvFileTransfer -> Maybe FilePath -> m FilePath
acceptFileReceive user@User {userId} RcvFileTransfer {fileId, fileInvitation = FileInvitation {fileName = fName, fileConnReq}, fileStatus, senderDisplayName, grpMemberId} filePath_ = do
  unless (fileStatus == RFSNew) . throwChatError $ CEFileAlreadyReceiving fName
  case fileConnReq of
    -- old file protocol
    Just connReq ->
      tryError (withAgent $ \a -> joinConnection a connReq . directMessage $ XFileAcpt fName) >>= \case
        Right agentConnId -> do
          filePath <- getRcvFilePath filePath_ fName
          withStore $ \st -> acceptRcvFileTransfer st userId fileId agentConnId filePath
          pure filePath
        Left e -> throwError e
    -- new file protocol
    Nothing ->
      case grpMemberId of
        Nothing -> do
          ct <- withStore $ \st -> getContactByName st userId senderDisplayName
          acceptFileV2 $ \sharedMsgId fileInvConnReq -> sendDirectContactMessage ct $ XFileAcptInv sharedMsgId fileInvConnReq fName
        Just memId -> do
          (GroupInfo {groupId}, GroupMember {activeConn}) <- withStore $ \st -> getGroupAndMember st user memId
          case activeConn of
            Just conn ->
              acceptFileV2 $ \sharedMsgId fileInvConnReq -> sendDirectMessage conn (XFileAcptInv sharedMsgId fileInvConnReq fName) (GroupId groupId)
            _ -> throwChatError $ CEFileInternal "member connection not active" -- should not happen
      where
        acceptFileV2 :: (SharedMsgId -> ConnReqInvitation -> m SndMessage) -> m FilePath
        acceptFileV2 sendXFileAcptInv = do
          sharedMsgId <- withStore $ \st -> getSharedMsgIdByFileId st userId fileId
          (agentConnId, fileInvConnReq) <- withAgent (`createConnection` SCMInvitation)
          filePath <- getRcvFilePath filePath_ fName
          withStore $ \st -> acceptRcvFileTransfer st userId fileId agentConnId filePath
          void $ sendXFileAcptInv sharedMsgId fileInvConnReq
          pure filePath
  where
    getRcvFilePath :: Maybe FilePath -> String -> m FilePath
    getRcvFilePath fPath_ fn = case fPath_ of
      Nothing ->
        asks filesFolder >>= readTVarIO >>= \case
          Nothing -> do
            dir <- (`combine` "Downloads") <$> getHomeDirectory
            ifM (doesDirectoryExist dir) (pure dir) getTemporaryDirectory
              >>= (`uniqueCombine` fn)
              >>= createEmptyFile
          Just filesFolder ->
            filesFolder `uniqueCombine` fn
              >>= createEmptyFile
              >>= pure <$> takeFileName
      Just fPath ->
        ifM
          (doesDirectoryExist fPath)
          (fPath `uniqueCombine` fn >>= createEmptyFile)
          $ ifM
            (doesFileExist fPath)
            (throwChatError $ CEFileAlreadyExists fPath)
            (createEmptyFile fPath)
      where
        createEmptyFile :: FilePath -> m FilePath
        createEmptyFile fPath = emptyFile fPath `E.catch` (throwChatError . CEFileWrite fPath . (show :: E.SomeException -> String))
        emptyFile :: FilePath -> m FilePath
        emptyFile fPath = do
          h <- getFileHandle fileId fPath rcvFiles AppendMode
          liftIO $ B.hPut h "" >> hFlush h
          pure fPath
        uniqueCombine :: FilePath -> String -> m FilePath
        uniqueCombine filePath fileName = tryCombine (0 :: Int)
          where
            tryCombine n =
              let (name, ext) = splitExtensions fileName
                  suffix = if n == 0 then "" else "_" <> show n
                  f = filePath `combine` (name <> suffix <> ext)
               in ifM (doesFileExist f) (tryCombine $ n + 1) (pure f)

acceptContactRequest :: ChatMonad m => User -> UserContactRequest -> m Contact
acceptContactRequest User {userId, profile} UserContactRequest {agentInvitationId = AgentInvId invId, localDisplayName = cName, profileId, profile = p, xContactId} = do
  connId <- withAgent $ \a -> acceptContact a invId . directMessage $ XInfo profile
  withStore $ \st -> createAcceptedContact st userId connId cName profileId p xContactId

agentSubscriber :: (MonadUnliftIO m, MonadReader ChatController m) => User -> m ()
agentSubscriber user = do
  q <- asks $ subQ . smpAgent
  l <- asks chatLock
  subscribeUserConnections user
  forever $ do
    (_, connId, msg) <- atomically $ readTBQueue q
    u <- readTVarIO =<< asks currentUser
    withLock l . void . runExceptT $
      processAgentMessage u connId msg `catchError` (toView . CRChatError)

subscribeUserConnections :: (MonadUnliftIO m, MonadReader ChatController m) => User -> m ()
subscribeUserConnections user@User {userId} = do
  n <- asks $ subscriptionConcurrency . config
  ce <- asks $ subscriptionEvents . config
  void . runExceptT $ do
    catchErr $ subscribeContacts n ce
    catchErr $ subscribeUserContactLink n
    catchErr $ subscribeGroups n ce
    catchErr $ subscribeFiles n
    catchErr $ subscribePendingConnections n
  where
    catchErr a = a `catchError` \_ -> pure ()
    subscribeContacts n ce = do
      contacts <- withStore (`getUserContacts` user)
      toView . CRContactSubSummary =<< pooledForConcurrentlyN n contacts (\ct -> ContactSubStatus ct <$> subscribeContact ce ct)
    subscribeContact ce ct =
      (subscribe (contactConnId ct) >> when ce (toView $ CRContactSubscribed ct) $> Nothing)
        `catchError` (\e -> when ce (toView $ CRContactSubError ct e) $> Just e)
    subscribeGroups n ce = do
      groups <- withStore (`getUserGroups` user)
      toView . CRMemberSubErrors . mconcat =<< forM groups (subscribeGroup n ce)
    subscribeGroup n ce (Group g@GroupInfo {membership} members) = do
      let connectedMembers = mapMaybe (\m -> (m,) <$> memberConnId m) members
      if memberStatus membership == GSMemInvited
        then do
          toView $ CRGroupInvitation g
          pure []
        else
          if null connectedMembers
            then do
              if memberActive membership
                then toView $ CRGroupEmpty g
                else toView $ CRGroupRemoved g
              pure []
            else do
              ms <- pooledForConcurrentlyN n connectedMembers $ \(m@GroupMember {localDisplayName = c}, cId) ->
                (m,) <$> ((subscribe cId $> Nothing) `catchError` (\e -> when ce (toView $ CRMemberSubError g c e) $> Just e))
              toView $ CRGroupSubscribed g
              pure $ mapMaybe (\(m, e) -> (Just . MemberSubError m) =<< e) ms
    subscribeFiles n = do
      sndFileTransfers <- withStore (`getLiveSndFileTransfers` user)
      pooledForConcurrentlyN_ n sndFileTransfers $ \sft -> subscribeSndFile sft
      rcvFileTransfers <- withStore (`getLiveRcvFileTransfers` user)
      pooledForConcurrentlyN_ n rcvFileTransfers $ \rft -> subscribeRcvFile rft
      where
        subscribeSndFile ft@SndFileTransfer {fileId, fileStatus, agentConnId = AgentConnId cId} = do
          subscribe cId `catchError` (toView . CRSndFileSubError ft)
          void . forkIO $ do
            threadDelay 1000000
            l <- asks chatLock
            a <- asks smpAgent
            unless (fileStatus == FSNew) . unlessM (isFileActive fileId sndFiles) $
              withAgentLock a . withLock l $
                sendFileChunk ft
        subscribeRcvFile ft@RcvFileTransfer {fileStatus} =
          case fileStatus of
            RFSAccepted fInfo -> resume fInfo
            RFSConnected fInfo -> resume fInfo
            _ -> pure ()
          where
            resume RcvFileInfo {agentConnId = AgentConnId cId} =
              subscribe cId `catchError` (toView . CRRcvFileSubError ft)
    subscribePendingConnections n = do
      cs <- withStore (`getPendingConnections` user)
      summary <- pooledForConcurrentlyN n cs $ \Connection {agentConnId = acId@(AgentConnId cId)} ->
        PendingSubStatus acId <$> ((subscribe cId $> Nothing) `catchError` (pure . Just))
      toView $ CRPendingSubSummary summary
    subscribeUserContactLink n = do
      cs <- withStore (`getUserContactLinkConnections` userId)
      (subscribeConns n cs >> toView CRUserContactLinkSubscribed)
        `catchError` (toView . CRUserContactLinkSubError)
    subscribe cId = withAgent (`subscribeConnection` cId)
    subscribeConns n conns =
      withAgent $ \a ->
        pooledForConcurrentlyN_ n conns $ \c -> subscribeConnection a (aConnId c)

processAgentMessage :: forall m. ChatMonad m => Maybe User -> ConnId -> ACommand 'Agent -> m ()
processAgentMessage Nothing _ _ = throwChatError CENoActiveUser
processAgentMessage (Just user@User {userId, profile}) agentConnId agentMessage =
  (withStore (\st -> getConnectionEntity st user agentConnId) >>= updateConnStatus) >>= \case
    RcvDirectMsgConnection conn contact_ ->
      processDirectMessage agentMessage conn contact_
    RcvGroupMsgConnection conn gInfo m ->
      processGroupMessage agentMessage conn gInfo m
    RcvFileConnection conn ft ->
      processRcvFileConn agentMessage conn ft
    SndFileConnection conn ft ->
      processSndFileConn agentMessage conn ft
    UserContactConnection conn uc ->
      processUserContactRequest agentMessage conn uc
  where
    updateConnStatus :: ConnectionEntity -> m ConnectionEntity
    updateConnStatus acEntity = case agentMsgConnStatus agentMessage of
      Just connStatus -> do
        let conn = (entityConnection acEntity) {connStatus}
        withStore $ \st -> updateConnectionStatus st conn connStatus
        pure $ updateEntityConnStatus acEntity connStatus
      Nothing -> pure acEntity

    isMember :: MemberId -> GroupInfo -> [GroupMember] -> Bool
    isMember memId GroupInfo {membership} members =
      sameMemberId memId membership || isJust (find (sameMemberId memId) members)

    agentMsgConnStatus :: ACommand 'Agent -> Maybe ConnStatus
    agentMsgConnStatus = \case
      CONF {} -> Just ConnRequested
      INFO _ -> Just ConnSndReady
      CON -> Just ConnReady
      _ -> Nothing

    processDirectMessage :: ACommand 'Agent -> Connection -> Maybe Contact -> m ()
    processDirectMessage agentMsg conn@Connection {connId} = \case
      Nothing -> case agentMsg of
        CONF confId connInfo -> do
          saveConnInfo conn connInfo
          allowAgentConnection conn confId $ XInfo profile
        INFO connInfo ->
          saveConnInfo conn connInfo
        MSG meta msgBody -> do
          _ <- saveRcvMSG conn (ConnectionId connId) meta msgBody
          withAckMessage agentConnId meta $ pure ()
          ackMsgDeliveryEvent conn meta
        SENT msgId ->
          -- ? updateDirectChatItemStatus
          sentMsgDeliveryEvent conn msgId
        -- TODO print errors
        MERR _ _ -> pure () -- ? updateDirectChatItemStatus
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()
      Just ct@Contact {localDisplayName = c, contactId} -> case agentMsg of
        MSG msgMeta msgBody -> do
          msg@RcvMessage {chatMsgEvent} <- saveRcvMSG conn (ConnectionId connId) msgMeta msgBody
          withAckMessage agentConnId msgMeta $
            case chatMsgEvent of
              XMsgNew mc -> newContentMessage ct mc msg msgMeta
              XMsgUpdate sharedMsgId mContent -> messageUpdate ct sharedMsgId mContent msg msgMeta
              XMsgDel sharedMsgId -> messageDelete ct sharedMsgId msg msgMeta
              -- TODO discontinue XFile
              XFile fInv -> processFileInvitation' ct fInv msg msgMeta
              XFileAcptInv sharedMsgId fileConnReq fName -> xFileAcptInv ct sharedMsgId fileConnReq fName msgMeta
              XInfo p -> xInfo ct p
              XGrpInv gInv -> processGroupInvitation ct gInv
              XInfoProbe probe -> xInfoProbe ct probe
              XInfoProbeCheck probeHash -> xInfoProbeCheck ct probeHash
              XInfoProbeOk probe -> xInfoProbeOk ct probe
              _ -> pure ()
          ackMsgDeliveryEvent conn msgMeta
        CONF confId connInfo -> do
          -- confirming direct connection with a member
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XGrpMemInfo _memId _memProfile -> do
              -- TODO check member ID
              -- TODO update member profile
              allowAgentConnection conn confId XOk
            _ -> messageError "CONF from member must have x.grp.mem.info"
        INFO connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XGrpMemInfo _memId _memProfile -> do
              -- TODO check member ID
              -- TODO update member profile
              pure ()
            XInfo _profile -> do
              -- TODO update contact profile
              pure ()
            XOk -> pure ()
            _ -> messageError "INFO for existing contact must have x.grp.mem.info, x.info or x.ok"
        CON ->
          withStore (\st -> getViaGroupMember st user ct) >>= \case
            Nothing -> do
              toView $ CRContactConnected ct
              setActive $ ActiveC c
              showToast (c <> "> ") "connected"
            Just (gInfo, m@GroupMember {activeConn}) -> do
              when (maybe False ((== ConnReady) . connStatus) activeConn) $ do
                notifyMemberConnected gInfo m
                when (memberCategory m == GCPreMember) $ probeMatchingContacts ct
        SENT msgId -> do
          sentMsgDeliveryEvent conn msgId
          chatItemId_ <- withStore $ \st -> getChatItemIdByAgentMsgId st connId msgId
          case chatItemId_ of
            Nothing -> pure ()
            Just chatItemId -> do
              chatItem <- withStore $ \st -> updateDirectChatItemStatus st userId contactId chatItemId CISSndSent
              toView $ CRChatItemStatusUpdated (AChatItem SCTDirect SMDSnd (DirectChat ct) chatItem)
        END -> do
          toView $ CRContactAnotherClient ct
          showToast (c <> "> ") "connected to another client"
          unsetActive $ ActiveC c
        DOWN -> do
          toView $ CRContactDisconnected ct
          showToast (c <> "> ") "disconnected"
        UP -> do
          toView $ CRContactSubscribed ct
          showToast (c <> "> ") "is active"
          setActive $ ActiveC c
        -- TODO print errors
        MERR msgId err -> do
          chatItemId_ <- withStore $ \st -> getChatItemIdByAgentMsgId st connId msgId
          case chatItemId_ of
            Nothing -> pure ()
            Just chatItemId -> do
              chatItem <- withStore $ \st -> updateDirectChatItemStatus st userId contactId chatItemId (agentErrToItemStatus err)
              toView $ CRChatItemStatusUpdated (AChatItem SCTDirect SMDSnd (DirectChat ct) chatItem)
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()

    processGroupMessage :: ACommand 'Agent -> Connection -> GroupInfo -> GroupMember -> m ()
    processGroupMessage agentMsg conn gInfo@GroupInfo {groupId, localDisplayName = gName, membership} m = case agentMsg of
      CONF confId connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case memberCategory m of
          GCInviteeMember ->
            case chatMsgEvent of
              XGrpAcpt memId
                | sameMemberId memId m -> do
                  withStore $ \st -> updateGroupMemberStatus st userId m GSMemAccepted
                  allowAgentConnection conn confId XOk
                | otherwise -> messageError "x.grp.acpt: memberId is different from expected"
              _ -> messageError "CONF from invited member must have x.grp.acpt"
          _ ->
            case chatMsgEvent of
              XGrpMemInfo memId _memProfile
                | sameMemberId memId m -> do
                  -- TODO update member profile
                  allowAgentConnection conn confId $ XGrpMemInfo (memberId (membership :: GroupMember)) profile
                | otherwise -> messageError "x.grp.mem.info: memberId is different from expected"
              _ -> messageError "CONF from member must have x.grp.mem.info"
      INFO connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case chatMsgEvent of
          XGrpMemInfo memId _memProfile
            | sameMemberId memId m -> do
              -- TODO update member profile
              pure ()
            | otherwise -> messageError "x.grp.mem.info: memberId is different from expected"
          XOk -> pure ()
          _ -> messageError "INFO from member must have x.grp.mem.info"
        pure ()
      CON -> do
        members <- withStore $ \st -> getGroupMembers st user gInfo
        withStore $ \st -> do
          updateGroupMemberStatus st userId m GSMemConnected
          unless (memberActive membership) $
            updateGroupMemberStatus st userId membership GSMemConnected
        sendPendingGroupMessages m conn
        case memberCategory m of
          GCHostMember -> do
            toView $ CRUserJoinedGroup gInfo
            setActive $ ActiveG gName
            showToast ("#" <> gName) "you are connected to group"
          GCInviteeMember -> do
            toView $ CRJoinedGroupMember gInfo m
            setActive $ ActiveG gName
            showToast ("#" <> gName) $ "member " <> localDisplayName (m :: GroupMember) <> " is connected"
            intros <- withStore $ \st -> createIntroductions st members m
            void . sendGroupMessage gInfo members . XGrpMemNew $ memberInfo m
            forM_ intros $ \intro@GroupMemberIntro {introId} -> do
              void $ sendDirectMessage conn (XGrpMemIntro . memberInfo $ reMember intro) (GroupId groupId)
              withStore $ \st -> updateIntroStatus st introId GMIntroSent
          _ -> do
            -- TODO send probe and decide whether to use existing contact connection or the new contact connection
            -- TODO notify member who forwarded introduction - question - where it is stored? There is via_contact but probably there should be via_member in group_members table
            withStore (\st -> getViaGroupContact st user m) >>= \case
              Nothing -> do
                notifyMemberConnected gInfo m
                messageError "implementation error: connected member does not have contact"
              Just ct@Contact {activeConn = Connection {connStatus}} ->
                when (connStatus == ConnReady) $ do
                  notifyMemberConnected gInfo m
                  when (memberCategory m == GCPreMember) $ probeMatchingContacts ct
      MSG msgMeta msgBody -> do
        msg@RcvMessage {chatMsgEvent} <- saveRcvMSG conn (GroupId groupId) msgMeta msgBody
        withAckMessage agentConnId msgMeta $
          case chatMsgEvent of
            XMsgNew mc -> newGroupContentMessage gInfo m mc msg msgMeta
            XMsgUpdate sharedMsgId mContent -> groupMessageUpdate gInfo m sharedMsgId mContent msg
            XMsgDel sharedMsgId -> groupMessageDelete gInfo m sharedMsgId msg
            -- TODO discontinue XFile
            XFile fInv -> processGroupFileInvitation' gInfo m fInv msg msgMeta
            XFileAcptInv sharedMsgId fileConnReq fName -> xFileAcptInvGroup gInfo m sharedMsgId fileConnReq fName msgMeta
            XGrpMemNew memInfo -> xGrpMemNew gInfo m memInfo
            XGrpMemIntro memInfo -> xGrpMemIntro conn gInfo m memInfo
            XGrpMemInv memId introInv -> xGrpMemInv gInfo m memId introInv
            XGrpMemFwd memInfo introInv -> xGrpMemFwd gInfo m memInfo introInv
            XGrpMemDel memId -> xGrpMemDel gInfo m memId
            XGrpLeave -> xGrpLeave gInfo m
            XGrpDel -> xGrpDel gInfo m
            _ -> messageError $ "unsupported message: " <> T.pack (show chatMsgEvent)
        ackMsgDeliveryEvent conn msgMeta
      SENT msgId ->
        sentMsgDeliveryEvent conn msgId
      -- TODO print errors
      MERR _ _ -> pure ()
      ERR _ -> pure ()
      -- TODO add debugging output
      _ -> pure ()

    processSndFileConn :: ACommand 'Agent -> Connection -> SndFileTransfer -> m ()
    processSndFileConn agentMsg conn ft@SndFileTransfer {fileId, fileName, fileStatus} =
      case agentMsg of
        -- old file protocol
        CONF confId connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            -- TODO save XFileAcpt message
            XFileAcpt name
              | name == fileName -> do
                withStore $ \st -> updateSndFileStatus st ft FSAccepted
                allowAgentConnection conn confId XOk
              | otherwise -> messageError "x.file.acpt: fileName is different from expected"
            _ -> messageError "CONF from file connection must have x.file.acpt"
        CON -> do
          withStore $ \st -> updateSndFileStatus st ft FSConnected
          toView $ CRSndFileStart ft
          sendFileChunk ft
        SENT msgId -> do
          withStore $ \st -> updateSndFileChunkSent st ft msgId
          unless (fileStatus == FSCancelled) $ sendFileChunk ft
        MERR _ err -> do
          cancelSndFileTransfer ft
          case err of
            SMP SMP.AUTH -> unless (fileStatus == FSCancelled) $ toView $ CRSndFileRcvCancelled ft
            _ -> throwChatError $ CEFileSend fileId err
        MSG meta _ ->
          withAckMessage agentConnId meta $ pure ()
        -- TODO print errors
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()

    processRcvFileConn :: ACommand 'Agent -> Connection -> RcvFileTransfer -> m ()
    processRcvFileConn agentMsg conn ft@RcvFileTransfer {fileId, chunkSize} =
      case agentMsg of
        -- new file protocol
        CONF confId connInfo -> do
          ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
          case chatMsgEvent of
            XOk -> allowAgentConnection conn confId XOk
            _ -> pure ()
        CON -> do
          withStore $ \st -> updateRcvFileStatus st ft FSConnected
          toView $ CRRcvFileStart ft
        MSG meta@MsgMeta {recipient = (msgId, _), integrity} msgBody -> withAckMessage agentConnId meta $ do
          parseFileChunk msgBody >>= \case
            FileChunkCancel -> do
              cancelRcvFileTransfer ft
              toView $ CRRcvFileSndCancelled ft
            FileChunk {chunkNo, chunkBytes = chunk} -> do
              case integrity of
                MsgOk -> pure ()
                MsgError MsgDuplicate -> pure () -- TODO remove once agent removes duplicates
                MsgError e ->
                  badRcvFileChunk ft $ "invalid file chunk number " <> show chunkNo <> ": " <> show e
              withStore (\st -> createRcvFileChunk st ft chunkNo msgId) >>= \case
                RcvChunkOk ->
                  if B.length chunk /= fromInteger chunkSize
                    then badRcvFileChunk ft "incorrect chunk size"
                    else appendFileChunk ft chunkNo chunk
                RcvChunkFinal ->
                  if B.length chunk > fromInteger chunkSize
                    then badRcvFileChunk ft "incorrect chunk size"
                    else do
                      appendFileChunk ft chunkNo chunk
                      ci <- withStore $ \st -> do
                        updateRcvFileStatus st ft FSComplete
                        updateCIFileStatus st userId fileId CIFSRcvComplete
                        deleteRcvFileChunks st ft
                        getChatItemByFileId st user fileId
                      toView $ CRRcvFileComplete ci
                      closeFileHandle fileId rcvFiles
                      withAgent (`deleteConnection` agentConnId)
                RcvChunkDuplicate -> pure ()
                RcvChunkError -> badRcvFileChunk ft $ "incorrect chunk number " <> show chunkNo
        -- TODO print errors
        MERR _ _ -> pure ()
        ERR _ -> pure ()
        -- TODO add debugging output
        _ -> pure ()

    processUserContactRequest :: ACommand 'Agent -> Connection -> UserContact -> m ()
    processUserContactRequest agentMsg _conn UserContact {userContactLinkId} = case agentMsg of
      REQ invId connInfo -> do
        ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
        case chatMsgEvent of
          XContact p xContactId_ -> profileContactRequest invId p xContactId_
          XInfo p -> profileContactRequest invId p Nothing
          -- TODO show/log error, other events in contact request
          _ -> pure ()
      -- TODO print errors
      MERR _ _ -> pure ()
      ERR _ -> pure ()
      -- TODO add debugging output
      _ -> pure ()
      where
        profileContactRequest :: InvitationId -> Profile -> Maybe XContactId -> m ()
        profileContactRequest invId p xContactId_ = do
          withStore (\st -> createOrUpdateContactRequest st userId userContactLinkId invId p xContactId_) >>= \case
            Left contact -> toView $ CRContactRequestAlreadyAccepted contact
            Right cReq@UserContactRequest {localDisplayName} -> do
              (_, autoAccept) <- withStore $ \st -> getUserContactLink st userId
              if autoAccept
                then acceptContactRequest user cReq >>= toView . CRAcceptingContactRequest
                else do
                  toView $ CRReceivedContactRequest cReq
                  showToast (localDisplayName <> "> ") "wants to connect to you"

    withAckMessage :: ConnId -> MsgMeta -> m () -> m ()
    withAckMessage cId MsgMeta {recipient = (msgId, _)} action =
      action `E.finally` withAgent (\a -> ackMessage a cId msgId `catchError` \_ -> pure ())

    ackMsgDeliveryEvent :: Connection -> MsgMeta -> m ()
    ackMsgDeliveryEvent Connection {connId} MsgMeta {recipient = (msgId, _)} =
      withStore $ \st -> createRcvMsgDeliveryEvent st connId msgId MDSRcvAcknowledged

    sentMsgDeliveryEvent :: Connection -> AgentMsgId -> m ()
    sentMsgDeliveryEvent Connection {connId} msgId =
      withStore $ \st -> createSndMsgDeliveryEvent st connId msgId MDSSndSent

    agentErrToItemStatus :: AgentErrorType -> CIStatus 'MDSnd
    agentErrToItemStatus (SMP AUTH) = CISSndErrorAuth
    agentErrToItemStatus err = CISSndError err

    badRcvFileChunk :: RcvFileTransfer -> String -> m ()
    badRcvFileChunk ft@RcvFileTransfer {fileStatus} err =
      case fileStatus of
        RFSCancelled _ -> pure ()
        _ -> do
          cancelRcvFileTransfer ft
          throwChatError $ CEFileRcvChunk err

    notifyMemberConnected :: GroupInfo -> GroupMember -> m ()
    notifyMemberConnected gInfo m@GroupMember {localDisplayName = c} = do
      toView $ CRConnectedToGroupMember gInfo m
      let g = groupName' gInfo
      setActive $ ActiveG g
      showToast ("#" <> g) $ "member " <> c <> " is connected"

    probeMatchingContacts :: Contact -> m ()
    probeMatchingContacts ct = do
      gVar <- asks idsDrg
      (probe, probeId) <- withStore $ \st -> createSentProbe st gVar userId ct
      void . sendDirectContactMessage ct $ XInfoProbe probe
      cs <- withStore (\st -> getMatchingContacts st userId ct)
      let probeHash = ProbeHash $ C.sha256Hash (unProbe probe)
      forM_ cs $ \c -> sendProbeHash c probeHash probeId `catchError` const (pure ())
      where
        sendProbeHash :: Contact -> ProbeHash -> Int64 -> m ()
        sendProbeHash c probeHash probeId = do
          void . sendDirectContactMessage c $ XInfoProbeCheck probeHash
          withStore $ \st -> createSentProbeHash st userId probeId c

    messageWarning :: Text -> m ()
    messageWarning = toView . CRMessageError "warning"

    messageError :: Text -> m ()
    messageError = toView . CRMessageError "error"

    newContentMessage :: Contact -> MsgContainer -> RcvMessage -> MsgMeta -> m ()
    newContentMessage ct@Contact {localDisplayName = c} mc msg msgMeta = do
      let (ExtMsgContent content fileInvitation_) = mcExtMsgContent mc
      ciFile_ <- processFileInvitation fileInvitation_ $
        \fi chSize -> withStore $ \st -> createRcvFileTransfer st userId ct fi chSize
      ci@ChatItem {formattedText} <- saveRcvChatItem user (CDDirectRcv ct) msg msgMeta (CIRcvMsgContent content) ciFile_
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      checkIntegrity msgMeta $ toView . CRMsgIntegrityError
      showMsgToast (c <> "> ") content formattedText
      setActive $ ActiveC c

    processFileInvitation :: Maybe FileInvitation -> (FileInvitation -> Integer -> m RcvFileTransfer) -> m (Maybe (CIFile 'MDRcv))
    processFileInvitation fileInvitation_ createRcvFileTransferF = case fileInvitation_ of
      Nothing -> pure Nothing
      Just fileInvitation@FileInvitation {fileName, fileSize} -> do
        chSize <- asks $ fileChunkSize . config
        RcvFileTransfer {fileId} <- createRcvFileTransferF fileInvitation chSize
        let ciFile = CIFile {fileId, fileName, fileSize, filePath = Nothing, fileStatus = CIFSRcvInvitation}
        pure $ Just ciFile

    messageUpdate :: Contact -> SharedMsgId -> MsgContent -> RcvMessage -> MsgMeta -> m ()
    messageUpdate ct@Contact {contactId} sharedMsgId mc RcvMessage {msgId} msgMeta = do
      CChatItem msgDir ChatItem {meta = CIMeta {itemId}} <- withStore $ \st -> getDirectChatItemBySharedMsgId st userId contactId sharedMsgId
      case msgDir of
        SMDRcv -> do
          updCi <- withStore $ \st -> updateDirectChatItem st userId contactId itemId (CIRcvMsgContent mc) msgId
          toView . CRChatItemUpdated $ AChatItem SCTDirect SMDRcv (DirectChat ct) updCi
          checkIntegrity msgMeta $ toView . CRMsgIntegrityError
        SMDSnd -> do
          messageError "x.msg.update: contact attempted invalid message update"
          checkIntegrity msgMeta $ toView . CRMsgIntegrityError

    messageDelete :: Contact -> SharedMsgId -> RcvMessage -> MsgMeta -> m ()
    messageDelete ct@Contact {contactId} sharedMsgId RcvMessage {msgId} msgMeta = do
      CChatItem msgDir deletedItem@ChatItem {meta = CIMeta {itemId}} <- withStore $ \st -> getDirectChatItemBySharedMsgId st userId contactId sharedMsgId
      case msgDir of
        SMDRcv -> do
          -- TODO allow to locally delete items that were broadcast deleted by sender
          toCi <- withStore $ \st -> deleteDirectChatItemRcvBroadcast st userId ct itemId msgId
          toView $ CRChatItemDeleted (AChatItem SCTDirect SMDRcv (DirectChat ct) deletedItem) toCi
          checkIntegrity msgMeta $ toView . CRMsgIntegrityError
        SMDSnd -> do
          messageError "x.msg.del: contact attempted invalid message delete"
          checkIntegrity msgMeta $ toView . CRMsgIntegrityError

    newGroupContentMessage :: GroupInfo -> GroupMember -> MsgContainer -> RcvMessage -> MsgMeta -> m ()
    newGroupContentMessage gInfo m@GroupMember {localDisplayName = c} mc msg msgMeta = do
      let (ExtMsgContent content fileInvitation_) = mcExtMsgContent mc
      ciFile_ <- processFileInvitation fileInvitation_ $
        \fi chSize -> withStore $ \st -> createRcvGroupFileTransfer st userId m fi chSize
      ci@ChatItem {formattedText} <- saveRcvChatItem user (CDGroupRcv gInfo m) msg msgMeta (CIRcvMsgContent content) ciFile_
      groupMsgToView gInfo ci msgMeta
      let g = groupName' gInfo
      showMsgToast ("#" <> g <> " " <> c <> "> ") content formattedText
      setActive $ ActiveG g

    groupMessageUpdate :: GroupInfo -> GroupMember -> SharedMsgId -> MsgContent -> RcvMessage -> m ()
    groupMessageUpdate gInfo@GroupInfo {groupId} GroupMember {memberId} sharedMsgId mc RcvMessage {msgId} = do
      CChatItem msgDir ChatItem {chatDir, meta = CIMeta {itemId}} <- withStore $ \st -> getGroupChatItemBySharedMsgId st user groupId sharedMsgId
      case (msgDir, chatDir) of
        (SMDRcv, CIGroupRcv m) ->
          if sameMemberId memberId m
            then do
              updCi <- withStore $ \st -> updateGroupChatItem st user groupId itemId (CIRcvMsgContent mc) msgId
              toView . CRChatItemUpdated $ AChatItem SCTGroup SMDRcv (GroupChat gInfo) updCi
            else messageError "x.msg.update: group member attempted to update a message of another member"
        (SMDSnd, _) -> messageError "x.msg.update: group member attempted invalid message update"

    groupMessageDelete :: GroupInfo -> GroupMember -> SharedMsgId -> RcvMessage -> m ()
    groupMessageDelete gInfo@GroupInfo {groupId} GroupMember {memberId} sharedMsgId RcvMessage {msgId} = do
      CChatItem msgDir deletedItem@ChatItem {chatDir, meta = CIMeta {itemId}} <- withStore $ \st -> getGroupChatItemBySharedMsgId st user groupId sharedMsgId
      case (msgDir, chatDir) of
        (SMDRcv, CIGroupRcv m) ->
          if sameMemberId memberId m
            then do
              toCi <- withStore $ \st -> deleteGroupChatItemRcvBroadcast st user gInfo itemId msgId
              toView $ CRChatItemDeleted (AChatItem SCTGroup SMDRcv (GroupChat gInfo) deletedItem) toCi
            else messageError "x.msg.del: group member attempted to delete a message of another member"
        (SMDSnd, _) -> messageError "x.msg.del: group member attempted invalid message delete"

    -- TODO remove once XFile is discontinued
    processFileInvitation' :: Contact -> FileInvitation -> RcvMessage -> MsgMeta -> m ()
    processFileInvitation' ct@Contact {localDisplayName = c} fInv@FileInvitation {fileName, fileSize} msg msgMeta = do
      -- TODO chunk size has to be sent as part of invitation
      chSize <- asks $ fileChunkSize . config
      RcvFileTransfer {fileId} <- withStore $ \st -> createRcvFileTransfer st userId ct fInv chSize
      let ciFile = Just $ CIFile {fileId, fileName, fileSize, filePath = Nothing, fileStatus = CIFSRcvInvitation}
      ci <- saveRcvChatItem user (CDDirectRcv ct) msg msgMeta (CIRcvMsgContent $ MCText "") ciFile
      toView . CRNewChatItem $ AChatItem SCTDirect SMDRcv (DirectChat ct) ci
      checkIntegrity msgMeta $ toView . CRMsgIntegrityError
      showToast (c <> "> ") "wants to send a file"
      setActive $ ActiveC c

    -- TODO remove once XFile is discontinued
    processGroupFileInvitation' :: GroupInfo -> GroupMember -> FileInvitation -> RcvMessage -> MsgMeta -> m ()
    processGroupFileInvitation' gInfo m@GroupMember {localDisplayName = c} fInv@FileInvitation {fileName, fileSize} msg msgMeta = do
      chSize <- asks $ fileChunkSize . config
      RcvFileTransfer {fileId} <- withStore $ \st -> createRcvGroupFileTransfer st userId m fInv chSize
      let ciFile = Just $ CIFile {fileId, fileName, fileSize, filePath = Nothing, fileStatus = CIFSRcvInvitation}
      ci <- saveRcvChatItem user (CDGroupRcv gInfo m) msg msgMeta (CIRcvMsgContent $ MCText "") ciFile
      groupMsgToView gInfo ci msgMeta
      let g = groupName' gInfo
      showToast ("#" <> g <> " " <> c <> "> ") "wants to send a file"
      setActive $ ActiveG g

    xFileAcptInv :: Contact -> SharedMsgId -> ConnReqInvitation -> String -> MsgMeta -> m ()
    xFileAcptInv Contact {contactId} sharedMsgId fileConnReq fName msgMeta = do
      checkIntegrity msgMeta $ toView . CRMsgIntegrityError
      fileId <- withStore $ \st -> getFileIdBySharedMsgId st userId contactId sharedMsgId
      withStore (\st -> getFileTransfer st userId fileId) >>= \case
        FTSnd FileTransferMeta {fileName, cancelled} _ ->
          if not cancelled
            then
              if fName == fileName
                then
                  tryError (withAgent $ \a -> joinConnection a fileConnReq . directMessage $ XOk) >>= \case
                    Right acId ->
                      withStore $ \st -> createSndFileTransferV2Connection st userId fileId acId
                    Left e -> throwError e
                else messageError "x.file.acpt.inv: fileName is different from expected"
            else pure () -- TODO send "file cancelled" message
        _ -> messageError "x.file.acpt.inv: bad file direction"

    xFileAcptInvGroup :: GroupInfo -> GroupMember -> SharedMsgId -> ConnReqInvitation -> String -> MsgMeta -> m ()
    xFileAcptInvGroup GroupInfo {groupId} m sharedMsgId fileConnReq fName msgMeta = do
      checkIntegrity msgMeta $ toView . CRMsgIntegrityError
      fileId <- withStore $ \st -> getGroupFileIdBySharedMsgId st userId groupId sharedMsgId
      withStore (\st -> getFileTransfer st userId fileId) >>= \case
        FTSnd FileTransferMeta {fileName, cancelled} _ ->
          if not cancelled
            then
              if fName == fileName
                then
                  tryError (withAgent $ \a -> joinConnection a fileConnReq . directMessage $ XOk) >>= \case
                    Right acId ->
                      withStore $ \st -> createSndGroupFileTransferV2Connection st userId fileId acId m
                    Left e -> throwError e
                else messageError "x.file.acpt.inv: fileName is different from expected"
            else pure () -- TODO send "file cancelled" message
        _ -> messageError "x.file.acpt.inv: bad file direction"

    groupMsgToView :: GroupInfo -> ChatItem 'CTGroup 'MDRcv -> MsgMeta -> m ()
    groupMsgToView gInfo ci msgMeta = do
      toView . CRNewChatItem $ AChatItem SCTGroup SMDRcv (GroupChat gInfo) ci
      checkIntegrity msgMeta $ toView . CRMsgIntegrityError

    processGroupInvitation :: Contact -> GroupInvitation -> m ()
    processGroupInvitation ct@Contact {localDisplayName = c} inv@(GroupInvitation (MemberIdRole fromMemId fromRole) (MemberIdRole memId memRole) _ _) = do
      when (fromRole < GRAdmin || fromRole < memRole) $ throwChatError (CEGroupContactRole c)
      when (fromMemId == memId) $ throwChatError CEGroupDuplicateMemberId
      gInfo@GroupInfo {localDisplayName = gName} <- withStore $ \st -> createGroupInvitation st user ct inv
      toView $ CRReceivedGroupInvitation gInfo ct memRole
      showToast ("#" <> gName <> " " <> c <> "> ") "invited you to join the group"

    checkIntegrity :: MsgMeta -> (MsgErrorType -> m ()) -> m ()
    checkIntegrity MsgMeta {integrity} action = case integrity of
      MsgError e -> action e
      MsgOk -> pure ()

    xInfo :: Contact -> Profile -> m ()
    xInfo c@Contact {profile = p} p' = unless (p == p') $ do
      c' <- withStore $ \st -> updateContactProfile st userId c p'
      toView $ CRContactUpdated c c'

    xInfoProbe :: Contact -> Probe -> m ()
    xInfoProbe c2 probe = do
      r <- withStore $ \st -> matchReceivedProbe st userId c2 probe
      forM_ r $ \c1 -> probeMatch c1 c2 probe

    xInfoProbeCheck :: Contact -> ProbeHash -> m ()
    xInfoProbeCheck c1 probeHash = do
      r <- withStore $ \st -> matchReceivedProbeHash st userId c1 probeHash
      forM_ r . uncurry $ probeMatch c1

    probeMatch :: Contact -> Contact -> Probe -> m ()
    probeMatch c1@Contact {profile = p1} c2@Contact {profile = p2} probe =
      when (p1 == p2) $ do
        void . sendDirectContactMessage c1 $ XInfoProbeOk probe
        mergeContacts c1 c2

    xInfoProbeOk :: Contact -> Probe -> m ()
    xInfoProbeOk c1 probe = do
      r <- withStore $ \st -> matchSentProbe st userId c1 probe
      forM_ r $ \c2 -> mergeContacts c1 c2

    mergeContacts :: Contact -> Contact -> m ()
    mergeContacts to from = do
      withStore $ \st -> mergeContactRecords st userId to from
      toView $ CRContactsMerged to from

    saveConnInfo :: Connection -> ConnInfo -> m ()
    saveConnInfo activeConn connInfo = do
      ChatMessage {chatMsgEvent} <- liftEither $ parseChatMessage connInfo
      case chatMsgEvent of
        XInfo p -> do
          ct <- withStore $ \st -> createDirectContact st userId activeConn p
          toView $ CRContactConnecting ct
        -- TODO show/log error, other events in SMP confirmation
        _ -> pure ()

    xGrpMemNew :: GroupInfo -> GroupMember -> MemberInfo -> m ()
    xGrpMemNew gInfo m memInfo@(MemberInfo memId _ _) = do
      members <- withStore $ \st -> getGroupMembers st user gInfo
      unless (sameMemberId memId $ membership gInfo) $
        if isMember memId gInfo members
          then messageError "x.grp.mem.new error: member already exists"
          else do
            newMember <- withStore $ \st -> createNewGroupMember st user gInfo memInfo GCPostMember GSMemAnnounced
            toView $ CRJoinedGroupMemberConnecting gInfo m newMember

    xGrpMemIntro :: Connection -> GroupInfo -> GroupMember -> MemberInfo -> m ()
    xGrpMemIntro conn gInfo@GroupInfo {groupId} m memInfo@(MemberInfo memId _ _) = do
      case memberCategory m of
        GCHostMember -> do
          members <- withStore $ \st -> getGroupMembers st user gInfo
          if isMember memId gInfo members
            then messageWarning "x.grp.mem.intro ignored: member already exists"
            else do
              (groupConnId, groupConnReq) <- withAgent (`createConnection` SCMInvitation)
              (directConnId, directConnReq) <- withAgent (`createConnection` SCMInvitation)
              newMember <- withStore $ \st -> createIntroReMember st user gInfo m memInfo groupConnId directConnId
              let msg = XGrpMemInv memId IntroInvitation {groupConnReq, directConnReq}
              void $ sendDirectMessage conn msg (GroupId groupId)
              withStore $ \st -> updateGroupMemberStatus st userId newMember GSMemIntroInvited
        _ -> messageError "x.grp.mem.intro can be only sent by host member"

    xGrpMemInv :: GroupInfo -> GroupMember -> MemberId -> IntroInvitation -> m ()
    xGrpMemInv gInfo m memId introInv = do
      case memberCategory m of
        GCInviteeMember -> do
          members <- withStore $ \st -> getGroupMembers st user gInfo
          case find (sameMemberId memId) members of
            Nothing -> messageError "x.grp.mem.inv error: referenced member does not exist"
            Just reMember -> do
              GroupMemberIntro {introId} <- withStore $ \st -> saveIntroInvitation st reMember m introInv
              void $ sendXGrpMemInv gInfo reMember (XGrpMemFwd (memberInfo m) introInv) introId
        _ -> messageError "x.grp.mem.inv can be only sent by invitee member"

    xGrpMemFwd :: GroupInfo -> GroupMember -> MemberInfo -> IntroInvitation -> m ()
    xGrpMemFwd gInfo@GroupInfo {membership} m memInfo@(MemberInfo memId _ _) introInv@IntroInvitation {groupConnReq, directConnReq} = do
      members <- withStore $ \st -> getGroupMembers st user gInfo
      toMember <- case find (sameMemberId memId) members of
        -- TODO if the missed messages are correctly sent as soon as there is connection before anything else is sent
        -- the situation when member does not exist is an error
        -- member receiving x.grp.mem.fwd should have also received x.grp.mem.new prior to that.
        -- For now, this branch compensates for the lack of delayed message delivery.
        Nothing -> withStore $ \st -> createNewGroupMember st user gInfo memInfo GCPostMember GSMemAnnounced
        Just m' -> pure m'
      withStore $ \st -> saveMemberInvitation st toMember introInv
      let msg = XGrpMemInfo (memberId (membership :: GroupMember)) profile
      groupConnId <- withAgent $ \a -> joinConnection a groupConnReq $ directMessage msg
      directConnId <- withAgent $ \a -> joinConnection a directConnReq $ directMessage msg
      withStore $ \st -> createIntroToMemberContact st userId m toMember groupConnId directConnId

    xGrpMemDel :: GroupInfo -> GroupMember -> MemberId -> m ()
    xGrpMemDel gInfo@GroupInfo {membership} m memId = do
      members <- withStore $ \st -> getGroupMembers st user gInfo
      if memberId (membership :: GroupMember) == memId
        then do
          mapM_ deleteMemberConnection members
          withStore $ \st -> updateGroupMemberStatus st userId membership GSMemRemoved
          toView $ CRDeletedMemberUser gInfo m
        else case find (sameMemberId memId) members of
          Nothing -> messageError "x.grp.mem.del with unknown member ID"
          Just member -> do
            let mRole = memberRole (m :: GroupMember)
            if mRole < GRAdmin || mRole < memberRole (member :: GroupMember)
              then messageError "x.grp.mem.del with insufficient member permissions"
              else do
                deleteMemberConnection member
                withStore $ \st -> updateGroupMemberStatus st userId member GSMemRemoved
                toView $ CRDeletedMember gInfo m member

    sameMemberId :: MemberId -> GroupMember -> Bool
    sameMemberId memId GroupMember {memberId} = memId == memberId

    xGrpLeave :: GroupInfo -> GroupMember -> m ()
    xGrpLeave gInfo m = do
      deleteMemberConnection m
      withStore $ \st -> updateGroupMemberStatus st userId m GSMemLeft
      toView $ CRLeftMember gInfo m

    xGrpDel :: GroupInfo -> GroupMember -> m ()
    xGrpDel gInfo m@GroupMember {memberRole} = do
      when (memberRole /= GROwner) $ throwChatError CEGroupUserRole
      ms <- withStore $ \st -> do
        members <- getGroupMembers st user gInfo
        updateGroupMemberStatus st userId (membership gInfo) GSMemGroupDeleted
        pure members
      mapM_ deleteMemberConnection ms
      toView $ CRGroupDeleted gInfo m

parseChatMessage :: ByteString -> Either ChatError ChatMessage
parseChatMessage = first (ChatError . CEInvalidChatMessage) . strDecode

sendFileChunk :: ChatMonad m => SndFileTransfer -> m ()
sendFileChunk ft@SndFileTransfer {fileId, fileStatus, agentConnId = AgentConnId acId} =
  unless (fileStatus == FSComplete || fileStatus == FSCancelled) $
    withStore (`createSndFileChunk` ft) >>= \case
      Just chunkNo -> sendFileChunkNo ft chunkNo
      Nothing -> do
        withStore $ \st -> do
          updateSndFileStatus st ft FSComplete
          deleteSndFileChunks st ft
        toView $ CRSndFileComplete ft
        closeFileHandle fileId sndFiles
        withAgent (`deleteConnection` acId)

sendFileChunkNo :: ChatMonad m => SndFileTransfer -> Integer -> m ()
sendFileChunkNo ft@SndFileTransfer {agentConnId = AgentConnId acId} chunkNo = do
  chunkBytes <- readFileChunk ft chunkNo
  msgId <- withAgent $ \a -> sendMessage a acId $ smpEncode FileChunk {chunkNo, chunkBytes}
  withStore $ \st -> updateSndFileChunkMsg st ft chunkNo msgId

readFileChunk :: ChatMonad m => SndFileTransfer -> Integer -> m ByteString
readFileChunk SndFileTransfer {fileId, filePath, chunkSize} chunkNo = do
  fsFilePath <- toFSFilePath filePath
  read_ fsFilePath `E.catch` (throwChatError . CEFileRead filePath . (show :: E.SomeException -> String))
  where
    read_ fsFilePath = do
      h <- getFileHandle fileId fsFilePath sndFiles ReadMode
      pos <- hTell h
      let pos' = (chunkNo - 1) * chunkSize
      when (pos /= pos') $ hSeek h AbsoluteSeek pos'
      liftIO . B.hGet h $ fromInteger chunkSize

data FileChunk = FileChunk {chunkNo :: Integer, chunkBytes :: ByteString} | FileChunkCancel

instance Encoding FileChunk where
  smpEncode = \case
    FileChunk {chunkNo, chunkBytes} -> smpEncode ('F', fromIntegral chunkNo :: Word32, Tail chunkBytes)
    FileChunkCancel -> smpEncode 'C'
  smpP =
    smpP >>= \case
      'F' -> do
        chunkNo <- fromIntegral <$> smpP @Word32
        Tail chunkBytes <- smpP
        pure FileChunk {chunkNo, chunkBytes}
      'C' -> pure FileChunkCancel
      _ -> fail "bad FileChunk"

parseFileChunk :: ChatMonad m => ByteString -> m FileChunk
parseFileChunk msg =
  liftEither . first (ChatError . CEFileRcvChunk) $ parseAll smpP msg

appendFileChunk :: ChatMonad m => RcvFileTransfer -> Integer -> ByteString -> m ()
appendFileChunk ft@RcvFileTransfer {fileId, fileStatus} chunkNo chunk =
  case fileStatus of
    RFSConnected RcvFileInfo {filePath} -> do
      fsFilePath <- toFSFilePath filePath
      append_ filePath fsFilePath
    RFSCancelled _ -> pure ()
    _ -> throwChatError $ CEFileInternal "receiving file transfer not in progress"
  where
    append_ fPath fPathUsed = do
      h <- getFileHandle fileId fPathUsed rcvFiles AppendMode
      E.try (liftIO $ B.hPut h chunk >> hFlush h) >>= \case
        Left (e :: E.SomeException) -> throwChatError . CEFileWrite fPath $ show e
        Right () -> withStore $ \st -> updatedRcvFileChunkStored st ft chunkNo

getFileHandle :: ChatMonad m => Int64 -> FilePath -> (ChatController -> TVar (Map Int64 Handle)) -> IOMode -> m Handle
getFileHandle fileId filePath files ioMode = do
  fs <- asks files
  h_ <- M.lookup fileId <$> readTVarIO fs
  maybe (newHandle fs) pure h_
  where
    newHandle fs = do
      -- TODO handle errors
      h <- liftIO (openFile filePath ioMode)
      atomically . modifyTVar fs $ M.insert fileId h
      pure h

isFileActive :: ChatMonad m => Int64 -> (ChatController -> TVar (Map Int64 Handle)) -> m Bool
isFileActive fileId files = do
  fs <- asks files
  isJust . M.lookup fileId <$> readTVarIO fs

cancelRcvFileTransfer :: ChatMonad m => RcvFileTransfer -> m ()
cancelRcvFileTransfer ft@RcvFileTransfer {fileId, fileStatus} = do
  closeFileHandle fileId rcvFiles
  withStore $ \st -> do
    updateRcvFileStatus st ft FSCancelled
    deleteRcvFileChunks st ft
  case fileStatus of
    RFSAccepted RcvFileInfo {agentConnId = AgentConnId acId} -> withAgent (`suspendConnection` acId)
    RFSConnected RcvFileInfo {agentConnId = AgentConnId acId} -> withAgent (`suspendConnection` acId)
    _ -> pure ()

cancelSndFileTransfer :: ChatMonad m => SndFileTransfer -> m ()
cancelSndFileTransfer ft@SndFileTransfer {agentConnId = AgentConnId acId, fileStatus} =
  unless (fileStatus == FSCancelled || fileStatus == FSComplete) $ do
    withStore $ \st -> do
      updateSndFileStatus st ft FSCancelled
      deleteSndFileChunks st ft
    withAgent $ \a -> do
      void (sendMessage a acId $ smpEncode FileChunkCancel) `catchError` \_ -> pure ()
      suspendConnection a acId

closeFileHandle :: ChatMonad m => Int64 -> (ChatController -> TVar (Map Int64 Handle)) -> m ()
closeFileHandle fileId files = do
  fs <- asks files
  h_ <- atomically . stateTVar fs $ \m -> (M.lookup fileId m, M.delete fileId m)
  mapM_ hClose h_ `E.catch` \(_ :: E.SomeException) -> pure ()

throwChatError :: ChatMonad m => ChatErrorType -> m a
throwChatError = throwError . ChatError

deleteMemberConnection :: ChatMonad m => GroupMember -> m ()
deleteMemberConnection m@GroupMember {activeConn} = do
  -- User {userId} <- asks currentUser
  withAgent (forM_ (memberConnId m) . deleteConnection) `catchError` const (pure ())
  -- withStore $ \st -> deleteGroupMemberConnection st userId m
  forM_ activeConn $ \conn -> withStore $ \st -> updateConnectionStatus st conn ConnDeleted

sendDirectContactMessage :: ChatMonad m => Contact -> ChatMsgEvent -> m SndMessage
sendDirectContactMessage ct@Contact {activeConn = conn@Connection {connId, connStatus}} chatMsgEvent = do
  if connStatus == ConnReady || connStatus == ConnSndReady
    then sendDirectMessage conn chatMsgEvent (ConnectionId connId)
    else throwChatError $ CEContactNotReady ct

sendDirectMessage :: ChatMonad m => Connection -> ChatMsgEvent -> ConnOrGroupId -> m SndMessage
sendDirectMessage conn chatMsgEvent connOrGroupId = do
  msg@SndMessage {msgId, msgBody} <- createSndMessage chatMsgEvent connOrGroupId
  deliverMessage conn msgBody msgId
  pure msg

createSndMessage :: ChatMonad m => ChatMsgEvent -> ConnOrGroupId -> m SndMessage
createSndMessage chatMsgEvent connOrGroupId = do
  gVar <- asks idsDrg
  withStore $ \st -> createNewSndMessage st gVar connOrGroupId $ \sharedMsgId ->
    let msgBody = strEncode ChatMessage {msgId = Just sharedMsgId, chatMsgEvent}
     in NewMessage {chatMsgEvent, msgBody}

directMessage :: ChatMsgEvent -> ByteString
directMessage chatMsgEvent = strEncode ChatMessage {msgId = Nothing, chatMsgEvent}

deliverMessage :: ChatMonad m => Connection -> MsgBody -> MessageId -> m ()
deliverMessage conn@Connection {connId} msgBody msgId = do
  agentMsgId <- withAgent $ \a -> sendMessage a (aConnId conn) msgBody
  let sndMsgDelivery = SndMsgDelivery {connId, agentMsgId}
  withStore $ \st -> createSndMsgDelivery st sndMsgDelivery msgId

sendGroupMessage :: ChatMonad m => GroupInfo -> [GroupMember] -> ChatMsgEvent -> m SndMessage
sendGroupMessage GroupInfo {groupId} members chatMsgEvent =
  sendGroupMessage' members chatMsgEvent groupId Nothing $ pure ()

sendXGrpMemInv :: ChatMonad m => GroupInfo -> GroupMember -> ChatMsgEvent -> Int64 -> m SndMessage
sendXGrpMemInv GroupInfo {groupId} reMember chatMsgEvent introId =
  sendGroupMessage' [reMember] chatMsgEvent groupId (Just introId) $
    withStore (\st -> updateIntroStatus st introId GMIntroInvForwarded)

sendGroupMessage' :: ChatMonad m => [GroupMember] -> ChatMsgEvent -> Int64 -> Maybe Int64 -> m () -> m SndMessage
sendGroupMessage' members chatMsgEvent groupId introId_ postDeliver = do
  msg@SndMessage {msgId, msgBody} <- createSndMessage chatMsgEvent (GroupId groupId)
  -- TODO collect failed deliveries into a single error
  forM_ (filter memberCurrent members) $ \m@GroupMember {groupMemberId} ->
    case memberConn m of
      Nothing -> withStore $ \st -> createPendingGroupMessage st groupMemberId msgId introId_
      Just conn@Connection {connStatus} ->
        if not (connStatus == ConnSndReady || connStatus == ConnReady)
          then unless (connStatus == ConnDeleted) $ withStore (\st -> createPendingGroupMessage st groupMemberId msgId introId_)
          else (deliverMessage conn msgBody msgId >> postDeliver) `catchError` const (pure ())
  pure msg

sendPendingGroupMessages :: ChatMonad m => GroupMember -> Connection -> m ()
sendPendingGroupMessages GroupMember {groupMemberId, localDisplayName} conn = do
  pendingMessages <- withStore $ \st -> getPendingGroupMessages st groupMemberId
  -- TODO ensure order - pending messages interleave with user input messages
  forM_ pendingMessages $ \PendingGroupMessage {msgId, cmEventTag, msgBody, introId_} -> do
    deliverMessage conn msgBody msgId
    withStore (\st -> deletePendingGroupMessage st groupMemberId msgId)
    when (cmEventTag == XGrpMemFwd_) $ case introId_ of
      Nothing -> throwChatError $ CEGroupMemberIntroNotFound localDisplayName
      Just introId -> withStore (\st -> updateIntroStatus st introId GMIntroInvForwarded)

saveRcvMSG :: ChatMonad m => Connection -> ConnOrGroupId -> MsgMeta -> MsgBody -> m RcvMessage
saveRcvMSG Connection {connId} connOrGroupId agentMsgMeta msgBody = do
  ChatMessage {msgId = sharedMsgId_, chatMsgEvent} <- liftEither $ parseChatMessage msgBody
  let agentMsgId = fst $ recipient agentMsgMeta
      newMsg = NewMessage {chatMsgEvent, msgBody}
      rcvMsgDelivery = RcvMsgDelivery {connId, agentMsgId, agentMsgMeta}
  withStore $ \st -> createNewMessageAndRcvMsgDelivery st connOrGroupId newMsg sharedMsgId_ rcvMsgDelivery

saveSndChatItem :: ChatMonad m => User -> ChatDirection c 'MDSnd -> SndMessage -> CIContent 'MDSnd -> Maybe (CIFile 'MDSnd) -> Maybe (CIQuote c) -> m (ChatItem c 'MDSnd)
saveSndChatItem user cd msg@SndMessage {sharedMsgId} content ciFile quotedItem = do
  createdAt <- liftIO getCurrentTime
  ciId <- withStore $ \st -> createNewSndChatItem st user cd msg content quotedItem createdAt
  forM_ ciFile $ \CIFile {fileId} -> withStore $ \st -> updateFileTransferChatItemId st fileId ciId
  liftIO $ mkChatItem cd ciId content ciFile quotedItem (Just sharedMsgId) createdAt createdAt

saveRcvChatItem :: ChatMonad m => User -> ChatDirection c 'MDRcv -> RcvMessage -> MsgMeta -> CIContent 'MDRcv -> Maybe (CIFile 'MDRcv) -> m (ChatItem c 'MDRcv)
saveRcvChatItem user cd msg@RcvMessage {sharedMsgId_} MsgMeta {broker = (_, brokerTs)} content ciFile = do
  createdAt <- liftIO getCurrentTime
  (ciId, quotedItem) <- withStore $ \st -> createNewRcvChatItem st user cd msg content brokerTs createdAt
  forM_ ciFile $ \CIFile {fileId} -> withStore $ \st -> updateFileTransferChatItemId st fileId ciId
  liftIO $ mkChatItem cd ciId content ciFile quotedItem sharedMsgId_ brokerTs createdAt

mkChatItem :: MsgDirectionI d => ChatDirection c d -> ChatItemId -> CIContent d -> Maybe (CIFile d) -> Maybe (CIQuote c) -> Maybe SharedMsgId -> ChatItemTs -> UTCTime -> IO (ChatItem c d)
mkChatItem cd ciId content file quotedItem sharedMsgId itemTs createdAt = do
  tz <- getCurrentTimeZone
  currentTs <- liftIO getCurrentTime
  let itemText = ciContentToText content
      meta = mkCIMeta ciId content itemText ciStatusNew sharedMsgId False False tz currentTs itemTs createdAt
  pure ChatItem {chatDir = toCIDirection cd, meta, content, formattedText = parseMaybeMarkdownList itemText, quotedItem, file}

allowAgentConnection :: ChatMonad m => Connection -> ConfirmationId -> ChatMsgEvent -> m ()
allowAgentConnection conn confId msg = do
  withAgent $ \a -> allowConnection a (aConnId conn) confId $ directMessage msg
  withStore $ \st -> updateConnectionStatus st conn ConnAccepted

getCreateActiveUser :: SQLiteStore -> IO User
getCreateActiveUser st = do
  user <-
    getUsers st >>= \case
      [] -> newUser
      users -> maybe (selectUser users) pure (find activeUser users)
  putStrLn $ "Current user: " <> userStr user
  pure user
  where
    newUser :: IO User
    newUser = do
      putStrLn
        "No user profiles found, it will be created now.\n\
        \Please choose your display name and your full name.\n\
        \They will be sent to your contacts when you connect.\n\
        \They are only stored on your device and you can change them later."
      loop
      where
        loop = do
          displayName <- getContactName
          fullName <- T.pack <$> getWithPrompt "full name (optional)"
          liftIO (runExceptT $ createUser st Profile {displayName, fullName, image = Nothing} True) >>= \case
            Left SEDuplicateName -> do
              putStrLn "chosen display name is already used by another profile on this device, choose another one"
              loop
            Left e -> putStrLn ("database error " <> show e) >> exitFailure
            Right user -> pure user
    selectUser :: [User] -> IO User
    selectUser [user] = do
      liftIO $ setActiveUser st (userId user)
      pure user
    selectUser users = do
      putStrLn "Select user profile:"
      forM_ (zip [1 ..] users) $ \(n :: Int, user) -> putStrLn $ show n <> " - " <> userStr user
      loop
      where
        loop = do
          nStr <- getWithPrompt $ "user profile number (1 .. " <> show (length users) <> ")"
          case readMaybe nStr :: Maybe Int of
            Nothing -> putStrLn "invalid user number" >> loop
            Just n
              | n <= 0 || n > length users -> putStrLn "invalid user number" >> loop
              | otherwise -> do
                let user = users !! (n - 1)
                liftIO $ setActiveUser st (userId user)
                pure user
    userStr :: User -> String
    userStr User {localDisplayName, profile = Profile {fullName}} =
      T.unpack $ localDisplayName <> if T.null fullName || localDisplayName == fullName then "" else " (" <> fullName <> ")"
    getContactName :: IO ContactName
    getContactName = do
      displayName <- getWithPrompt "display name (no spaces)"
      if null displayName || isJust (find (== ' ') displayName)
        then putStrLn "display name has space(s), choose another one" >> getContactName
        else pure $ T.pack displayName
    getWithPrompt :: String -> IO String
    getWithPrompt s = putStr (s <> ": ") >> hFlush stdout >> getLine

showMsgToast :: (MonadUnliftIO m, MonadReader ChatController m) => Text -> MsgContent -> Maybe MarkdownList -> m ()
showMsgToast from mc md_ = showToast from $ maybe (msgContentText mc) (mconcat . map hideSecret) md_
  where
    hideSecret :: FormattedText -> Text
    hideSecret FormattedText {format = Just Secret} = "..."
    hideSecret FormattedText {text} = text

showToast :: (MonadUnliftIO m, MonadReader ChatController m) => Text -> Text -> m ()
showToast title text = atomically . (`writeTBQueue` Notification {title, text}) =<< asks notifyQ

notificationSubscriber :: (MonadUnliftIO m, MonadReader ChatController m) => m ()
notificationSubscriber = do
  ChatController {notifyQ, sendNotification} <- ask
  forever $ atomically (readTBQueue notifyQ) >>= liftIO . sendNotification

withUser' :: ChatMonad m => (User -> m a) -> m a
withUser' action =
  asks currentUser
    >>= readTVarIO
    >>= maybe (throwChatError CENoActiveUser) action

withUser :: ChatMonad m => (User -> m a) -> m a
withUser action = withUser' $ \user ->
  ifM chatStarted (action user) (throwChatError CEChatNotStarted)
  where
    chatStarted = fmap isJust . readTVarIO =<< asks agentAsync

withAgent :: ChatMonad m => (AgentClient -> ExceptT AgentErrorType m a) -> m a
withAgent action =
  asks smpAgent
    >>= runExceptT . action
    >>= liftEither . first ChatErrorAgent

withStore ::
  ChatMonad m =>
  (forall m'. (MonadUnliftIO m', MonadError StoreError m') => SQLiteStore -> m' a) ->
  m a
withStore action =
  asks chatStore
    >>= runExceptT . action
    -- use this line instead of above to log query errors
    -- >>= (\st -> runExceptT $ action st `E.catch` \(e :: E.SomeException) -> liftIO (print e) >> E.throwIO e)
    >>= liftEither . first ChatErrorStore

chatCommandP :: Parser ChatCommand
chatCommandP =
  ("/user " <|> "/u ") *> (CreateActiveUser <$> userProfile)
    <|> ("/user" <|> "/u") $> ShowActiveUser
    <|> "/_start" $> StartChat
    <|> "/_files_folder " *> (SetFilesFolder <$> filePath)
    <|> "/_get chats" $> APIGetChats
    <|> "/_get chat " *> (APIGetChat <$> chatTypeP <*> A.decimal <* A.space <*> chatPaginationP)
    <|> "/_get items count=" *> (APIGetChatItems <$> A.decimal)
    <|> "/_send " *> (APISendMessage <$> chatTypeP <*> A.decimal <*> optional filePathTagged <*> optional quotedItemIdTagged <* A.space <*> msgContentP)
    <|> "/_send_quote " *> (APISendMessageQuote <$> chatTypeP <*> A.decimal <* A.space <*> A.decimal <* A.space <*> msgContentP)
    <|> "/_update item " *> (APIUpdateChatItem <$> chatTypeP <*> A.decimal <* A.space <*> A.decimal <* A.space <*> msgContentP)
    <|> "/_delete item " *> (APIDeleteChatItem <$> chatTypeP <*> A.decimal <* A.space <*> A.decimal <* A.space <*> ciDeleteMode)
    <|> "/_read chat " *> (APIChatRead <$> chatTypeP <*> A.decimal <* A.space <*> ((,) <$> ("from=" *> A.decimal) <* A.space <*> ("to=" *> A.decimal)))
    <|> "/_delete " *> (APIDeleteChat <$> chatTypeP <*> A.decimal)
    <|> "/_accept " *> (APIAcceptContact <$> A.decimal)
    <|> "/_reject " *> (APIRejectContact <$> A.decimal)
    <|> "/_profile " *> (APIUpdateProfile <$> jsonP)
    <|> "/_parse " *> (APIParseMarkdown . safeDecodeUtf8 <$> A.takeByteString)
    <|> "/smp_servers default" $> SetUserSMPServers []
    <|> "/smp_servers " *> (SetUserSMPServers <$> smpServersP)
    <|> "/smp_servers" $> GetUserSMPServers
    <|> ("/help files" <|> "/help file" <|> "/hf") $> ChatHelp HSFiles
    <|> ("/help groups" <|> "/help group" <|> "/hg") $> ChatHelp HSGroups
    <|> ("/help address" <|> "/ha") $> ChatHelp HSMyAddress
    <|> ("/help messages" <|> "/hm") $> ChatHelp HSMessages
    <|> ("/help" <|> "/h") $> ChatHelp HSMain
    <|> ("/group #" <|> "/group " <|> "/g #" <|> "/g ") *> (NewGroup <$> groupProfile)
    <|> ("/add #" <|> "/add " <|> "/a #" <|> "/a ") *> (AddMember <$> displayName <* A.space <*> displayName <*> memberRole)
    <|> ("/join #" <|> "/join " <|> "/j #" <|> "/j ") *> (JoinGroup <$> displayName)
    <|> ("/remove #" <|> "/remove " <|> "/rm #" <|> "/rm ") *> (RemoveMember <$> displayName <* A.space <*> displayName)
    <|> ("/leave #" <|> "/leave " <|> "/l #" <|> "/l ") *> (LeaveGroup <$> displayName)
    <|> ("/delete #" <|> "/d #") *> (DeleteGroup <$> displayName)
    <|> ("/members #" <|> "/members " <|> "/ms #" <|> "/ms ") *> (ListMembers <$> displayName)
    <|> ("/groups" <|> "/gs") $> ListGroups
    <|> A.char '#' *> (SendGroupMessage <$> displayName <* A.space <*> A.takeByteString)
    <|> (">#" <|> "> #") *> (SendGroupMessageQuote <$> displayName <* A.space <*> pure Nothing <*> quotedMsg <*> A.takeByteString)
    <|> (">#" <|> "> #") *> (SendGroupMessageQuote <$> displayName <* A.space <* optional (A.char '@') <*> (Just <$> displayName) <* A.space <*> quotedMsg <*> A.takeByteString)
    <|> ("\\#" <|> "\\ #") *> (DeleteGroupMessage <$> displayName <* A.space <*> A.takeByteString)
    <|> ("!#" <|> "! #") *> (EditGroupMessage <$> displayName <* A.space <*> (quotedMsg <|> pure "") <*> A.takeByteString)
    <|> ("/contacts" <|> "/cs") $> ListContacts
    <|> ("/connect " <|> "/c ") *> (Connect <$> ((Just <$> strP) <|> A.takeByteString $> Nothing))
    <|> ("/connect" <|> "/c") $> AddContact
    <|> ("/delete @" <|> "/delete " <|> "/d @" <|> "/d ") *> (DeleteContact <$> displayName)
    <|> A.char '@' *> (SendMessage <$> displayName <* A.space <*> A.takeByteString)
    <|> (">@" <|> "> @") *> sendMsgQuote (AMsgDirection SMDRcv)
    <|> (">>@" <|> ">> @") *> sendMsgQuote (AMsgDirection SMDSnd)
    <|> ("\\@" <|> "\\ @") *> (DeleteMessage <$> displayName <* A.space <*> A.takeByteString)
    <|> ("!@" <|> "! @") *> (EditMessage <$> displayName <* A.space <*> (quotedMsg <|> pure "") <*> A.takeByteString)
    <|> "/feed " *> (SendMessageBroadcast <$> A.takeByteString)
    <|> ("/file #" <|> "/f #") *> (SendGroupFile <$> displayName <* A.space <*> filePath)
    <|> ("/file_v2 #" <|> "/f_v2 #") *> (SendGroupFileInv <$> displayName <* A.space <*> filePath)
    <|> ("/file @" <|> "/file " <|> "/f @" <|> "/f ") *> (SendFile <$> displayName <* A.space <*> filePath)
    <|> ("/file_v2 @" <|> "/file_v2 " <|> "/f_v2 @" <|> "/f_v2 ") *> (SendFileInv <$> displayName <* A.space <*> filePath)
    <|> ("/freceive " <|> "/fr ") *> (ReceiveFile <$> A.decimal <*> optional (A.space *> filePath))
    <|> ("/fcancel " <|> "/fc ") *> (CancelFile <$> A.decimal)
    <|> ("/fstatus " <|> "/fs ") *> (FileStatus <$> A.decimal)
    <|> "/simplex" $> ConnectSimplex
    <|> ("/address" <|> "/ad") $> CreateMyAddress
    <|> ("/delete_address" <|> "/da") $> DeleteMyAddress
    <|> ("/show_address" <|> "/sa") $> ShowMyAddress
    <|> "/auto_accept " *> (AddressAutoAccept <$> onOffP)
    <|> ("/accept @" <|> "/accept " <|> "/ac @" <|> "/ac ") *> (AcceptContact <$> displayName)
    <|> ("/reject @" <|> "/reject " <|> "/rc @" <|> "/rc ") *> (RejectContact <$> displayName)
    <|> ("/markdown" <|> "/m") $> ChatHelp HSMarkdown
    <|> ("/welcome" <|> "/w") $> Welcome
    <|> "/profile_image " *> (UpdateProfileImage . Just . ImageData <$> imageP)
    <|> "/profile_image" $> UpdateProfileImage Nothing
    <|> ("/profile " <|> "/p ") *> (uncurry UpdateProfile <$> userNames)
    <|> ("/profile" <|> "/p") $> ShowProfile
    <|> ("/quit" <|> "/q" <|> "/exit") $> QuitChat
    <|> ("/version" <|> "/v") $> ShowVersion
  where
    imagePrefix = (<>) <$> "data:" <*> ("image/png;base64," <|> "image/jpg;base64,")
    imageP = safeDecodeUtf8 <$> ((<>) <$> imagePrefix <*> (B64.encode <$> base64P))
    chatTypeP = A.char '@' $> CTDirect <|> A.char '#' $> CTGroup
    chatPaginationP =
      (CPLast <$ "count=" <*> A.decimal)
        <|> (CPAfter <$ "after=" <*> A.decimal <* A.space <* "count=" <*> A.decimal)
        <|> (CPBefore <$ "before=" <*> A.decimal <* A.space <* "count=" <*> A.decimal)
    msgContentP =
      "text " *> (MCText . safeDecodeUtf8 <$> A.takeByteString)
        <|> "json " *> jsonP
    ciDeleteMode = "broadcast" $> CIDMBroadcast <|> "internal" $> CIDMInternal
    displayName = safeDecodeUtf8 <$> (B.cons <$> A.satisfy refChar <*> A.takeTill (== ' '))
    sendMsgQuote msgDir = SendMessageQuote <$> displayName <* A.space <*> pure msgDir <*> quotedMsg <*> A.takeByteString
    quotedMsg = A.char '(' *> A.takeTill (== ')') <* A.char ')' <* optional A.space
    refChar c = c > ' ' && c /= '#' && c /= '@'
    onOffP = ("on" $> True) <|> ("off" $> False)
    userNames = do
      cName <- displayName
      fullName <- fullNameP cName
      pure (cName, fullName)
    userProfile = do
      (cName, fullName) <- userNames
      pure Profile {displayName = cName, fullName, image = Nothing}
    jsonP :: J.FromJSON a => Parser a
    jsonP = J.eitherDecodeStrict' <$?> A.takeByteString
    groupProfile = do
      gName <- displayName
      fullName <- fullNameP gName
      pure GroupProfile {displayName = gName, fullName, image = Nothing}
    fullNameP name = do
      n <- (A.space *> A.takeByteString) <|> pure ""
      pure $ if B.null n then name else safeDecodeUtf8 n
    filePath = T.unpack . safeDecodeUtf8 <$> A.takeByteString
    filePathTagged = " file " *> (T.unpack . safeDecodeUtf8 <$> A.takeTill (== ' '))
    quotedItemIdTagged = " quoted " *> A.decimal
    memberRole =
      (" owner" $> GROwner)
        <|> (" admin" $> GRAdmin)
        <|> (" member" $> GRMember)
        <|> pure GRAdmin

adminContactReq :: ConnReqContact
adminContactReq =
  either error id $ strDecode "https://simplex.chat/contact#/?v=1&smp=smp%3A%2F%2FPQUV2eL0t7OStZOoAsPEV2QYWt4-xilbakvGUGOItUo%3D%40smp6.simplex.im%2FK1rslx-m5bpXVIdMZg9NLUZ_8JBm8xTt%23MCowBQYDK2VuAyEALDeVe-sG8mRY22LsXlPgiwTNs9dbiLrNuA7f3ZMAJ2w%3D"
