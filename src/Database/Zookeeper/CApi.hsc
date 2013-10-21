{-# LANGUAGE Safe                     #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- This file is part of zhk
--
-- All rights reserved.
--  
-- Redistribution and use in source and binary forms, with or without modification,
-- are permitted provided that the following conditions are met:
--  
--   Redistributions of source code must retain the above copyright notice, this
--   list of conditions and the following disclaimer.
--  
--   Redistributions in binary form must reproduce the above copyright notice, this
--   list of conditions and the following disclaimer in the documentation and/or
--   other materials provided with the distribution.
--  
--   Neither the name of the {organization} nor the names of its
--   contributors may be used to endorse or promote products derived from
--   this software without specific prior written permission.
--  
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
-- ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
-- ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module Database.Zookeeper.CApi
       ( -- * C to Haskell
         toStat
       , toState
       , toZKError
       , allocaStat
       , toClientId
         -- * Haskell to C
       , withAclList
       , wrapWatcher
       , fromLogLevel
       , fromCreateFlag
       , fromCreateFlags
       , wrapAclCompletion
       , wrapDataCompletion
       , wrapVoidCompletion
       , wrapStringCompletion
       , wrapStringsCompletion
         -- * Error handling
       , tryZ
       , isZOK
       , onZOK
       , whenZOK
         -- * C functions
       , c_zooSet2
       , c_zooAWGet
       , c_zooState
       , c_zooDelete
       , c_zooSetAcl
       , c_zooAGetAcl
       , c_zooACreate
       , c_zooAddAuth
       , c_zooWExists
       , c_zooClientId
       , c_zookeeperInit
       , c_zookeeperClose
       , c_zooSetWatcher
       , c_zooRecvTimeout
       , c_isUnrecoverable
       , c_zooAWGetChildren
       , c_zooSetDebugLevel
       ) where

#include <zookeeper.h>

import           Foreign.C
import           Foreign.Safe
import qualified Data.ByteString as B
import           Control.Applicative
import           Database.Zookeeper.Types

tryZ :: IO CInt -> IO a -> IO (Either ZKError a)
tryZ zkIO nextIO = do
  rc <- zkIO
  rc `onZOK` nextIO

isZOK :: CInt -> Bool
isZOK rc = rc == (#const ZOK)

onZOK :: CInt -> IO a -> IO (Either ZKError a)
onZOK rc nextIO
  | isZOK rc  = fmap Right nextIO
  | otherwise = return (Left $ toZKError rc)

whenZOK :: CInt -> IO (Either ZKError a) -> IO (Either ZKError a)
whenZOK rc succIO
  | isZOK rc  = succIO
  | otherwise = return (Left $ toZKError rc)

toStat :: Ptr CStat -> IO Stat
toStat ptr = Stat <$> (#peek struct Stat, czxid) ptr
                  <*> (#peek struct Stat, mzxid) ptr
                  <*> (#peek struct Stat, pzxid) ptr
                  <*> (#peek struct Stat, ctime) ptr
                  <*> (#peek struct Stat, mtime) ptr
                  <*> (#peek struct Stat, version) ptr
                  <*> (#peek struct Stat, cversion) ptr
                  <*> (#peek struct Stat, aversion) ptr
                  <*> (#peek struct Stat, dataLength) ptr
                  <*> (#peek struct Stat, numChildren) ptr
                  <*> liftA toEphemeralOwner ((#peek struct Stat, ephemeralOwner) ptr)
    where
      toEphemeralOwner 0 = Nothing
      toEphemeralOwner c = Just c

fromCreateFlag :: CreateFlag -> CInt
fromCreateFlag Sequence  = (#const ZOO_SEQUENCE)
fromCreateFlag Ephemeral = (#const ZOO_EPHEMERAL)

fromCreateFlags :: [CreateFlag] -> CInt
fromCreateFlags = foldr (.|.) 0 . map fromCreateFlag

fromPerm :: Perm -> CInt
fromPerm CanRead   = (#const ZOO_PERM_READ)
fromPerm CanAdmin  = (#const ZOO_PERM_ADMIN)
fromPerm CanWrite  = (#const ZOO_PERM_WRITE)
fromPerm CanCreate = (#const ZOO_PERM_CREATE)
fromPerm CanDelete = (#const ZOO_PERM_DELETE)

fromLogLevel :: ZLogLevel -> CInt
fromLogLevel ZLogError = (#const ZOO_LOG_LEVEL_ERROR)
fromLogLevel ZLogWarn  = (#const ZOO_LOG_LEVEL_WARN)
fromLogLevel ZLogInfo  = (#const ZOO_LOG_LEVEL_INFO)
fromLogLevel ZLogDebug = (#const ZOO_LOG_LEVEL_DEBUG)

fromPerms :: [Perm] -> CInt
fromPerms = foldr (.|.) 0 . map fromPerm

toPerms :: CInt -> [Perm]
toPerms n = buildList [ ((#const ZOO_PERM_READ), CanRead)
                      , ((#const ZOO_PERM_ADMIN), CanAdmin)
                      , ((#const ZOO_PERM_WRITE), CanWrite)
                      , ((#const ZOO_PERM_CREATE), CanCreate)
                      , ((#const ZOO_PERM_DELETE), CanDelete)
                      ]
    where
      buildList [] = []
      buildList ((t, a):xs)
        | n .&. t == t = a : buildList xs
        | otherwise    = buildList xs

toStringList :: Ptr CStrVec -> IO [String]
toStringList strvPtr = do
  count   <- (#peek struct String_vector, count) strvPtr
  dataPtr <- (#peek struct String_vector, data) strvPtr
  buildList [] count dataPtr
    where
      buildList :: [String] -> Int32 -> Ptr CString -> IO [String]
      buildList acc 0 _   = return $ reverse acc
      buildList acc n ptr = do
        item <- peek ptr >>= peekCString
        buildList (item : acc) (n-1) (ptr `plusPtr` (sizeOf ptr))

toClientId :: Ptr CClientID -> IO Int64
toClientId clientPtr = (#peek clientid_t, client_id) clientPtr

allocaStat :: (Ptr CStat -> IO a) -> IO a
allocaStat fun = allocaBytes (#size struct Stat) fun

toAclList :: Ptr CAclVec -> IO AclList
toAclList aclvPtr = do
  count  <- (#peek struct ACL_vector, count) aclvPtr
  aclPtr <- (#peek struct ACL_vector, data) aclvPtr
  fmap List (buildList [] count aclPtr)
    where
      buildList :: [Acl] -> Int32 -> Ptr CAcl -> IO [Acl]
      buildList acc 0 _   = return acc
      buildList acc n ptr = do
        acl <- Acl <$> ((#peek struct ACL, id.scheme) ptr >>= peekCString)
                   <*> ((#peek struct ACL, id.id) ptr >>= peekCString)
                   <*> (fmap toPerms ((#peek struct ACL, perms) ptr))
        buildList (acl : acc) (n-1) (ptr `plusPtr` (#size struct ACL))

withAclList :: AclList -> (Ptr CAclVec -> IO a) -> IO a
withAclList CreatorAll cont    = cont c_zooCreatorAclAll
withAclList OpenAclUnsafe cont = cont c_zooOpenAclUnsafe
withAclList ReadAclUnsafe cont = cont c_zooReadAclUnsafe
withAclList (List acls) cont   =
  allocaBytes (#size struct ACL_vector) $ \aclvPtr -> do
    (#poke struct ACL_vector, count) aclvPtr count
    allocaBytes (count * (#size struct ACL)) $ \aclPtr -> do
      (#poke struct ACL_vector, data) aclvPtr aclPtr
      pokeAcls acls aclvPtr aclPtr
    where
      count = length acls

      pokeAcls [] aclvPtr _              = cont aclvPtr
      pokeAcls (acl:rest) aclvPtr aclPtr = do
        withCString (aclScheme acl) $ \schemePtr -> do
          withCString (aclId acl) $ \idPtr -> do
            (#poke struct ACL, id.id) aclPtr idPtr
            (#poke struct ACL, perms) aclPtr (fromPerms (aclFlags acl))
            (#poke struct ACL, id.scheme) aclPtr schemePtr
            pokeAcls rest aclvPtr (aclPtr `plusPtr` (#size struct ACL))

toZKError :: CInt -> ZKError
toZKError (#const ZNONODE)                  = NoNodeError
toZKError (#const ZNOAUTH)                  = NoAuthError
toZKError (#const ZCLOSING)                 = ClosingError
toZKError (#const ZNOTHING)                 = NothingError
toZKError (#const ZAPIERROR)                = ApiError
toZKError (#const ZNOTEMPTY)                = NotEmptyError
toZKError (#const ZBADVERSION)              = BadVersionError
toZKError (#const ZINVALIDACL)              = InvalidACLError
toZKError (#const ZAUTHFAILED)              = AuthFailedError
toZKError (#const ZNODEEXISTS)              = NodeExistsError
toZKError (#const ZSYSTEMERROR)             = SystemError
toZKError (#const ZBADARGUMENTS)            = BadArgumentsError
toZKError (#const ZINVALIDSTATE)            = InvalidStateError
toZKError (#const ZSESSIONMOVED)            = SessionMovedError
toZKError (#const ZUNIMPLEMENTED)           = UnimplmenetedError
toZKError (#const ZCONNECTIONLOSS)          = ConnectionLossError
toZKError (#const ZSESSIONEXPIRED)          = SessionExpiredError
toZKError (#const ZINVALIDCALLBACK)         = InvalidCallbackError
toZKError (#const ZMARSHALLINGERROR)        = MarshallingError
toZKError (#const ZOPERATIONTIMEOUT)        = OperationTimeoutError
toZKError (#const ZDATAINCONSISTENCY)       = DataInconsistencyError
toZKError (#const ZRUNTIMEINCONSISTENCY)    = RuntimeInconsistencyError
toZKError (#const ZNOCHILDRENFOREPHEMERALS) = NoChildrenForEphemeralsError
toZKError code                              = (UnknownError $ fromIntegral code)

toState :: CInt -> State
toState (#const ZOO_CONNECTED_STATE)       = ConnectedState
toState (#const ZOO_CONNECTING_STATE)      = ConnectingState
toState (#const ZOO_ASSOCIATING_STATE)     = AssociatingState
toState (#const ZOO_AUTH_FAILED_STATE)     = AuthFailedState
toState (#const ZOO_EXPIRED_SESSION_STATE) = ExpiredSessionState
toState code                               = UnknownState $ fromIntegral code

toEvent :: CInt -> Event
toEvent (#const ZOO_CHILD_EVENT)       = ChildEvent
toEvent (#const ZOO_CREATED_EVENT)     = CreatedEvent
toEvent (#const ZOO_DELETED_EVENT)     = DeletedEvent
toEvent (#const ZOO_CHANGED_EVENT)     = ChangedEvent
toEvent (#const ZOO_SESSION_EVENT)     = SessionEvent
toEvent (#const ZOO_NOTWATCHING_EVENT) = NotWatchingEvent
toEvent code                           = UnknownEvent $ fromIntegral code

wrapWatcher :: Maybe Watcher -> IO (FunPtr CWatcherFn)
wrapWatcher Nothing   = return nullFunPtr
wrapWatcher (Just fn) = c_watcherFn $ \zh cevent cstate cpath _ -> do
  let event = toEvent cevent
      state = toState cstate
  path <- if (cpath == nullPtr)
            then return Nothing
            else fmap Just (peekCString cpath)
  fn (Zookeeper zh) event state path

wrapAclCompletion :: AclCompletion -> IO (FunPtr CAclCompletionFn)
wrapAclCompletion fn =
  c_aclCompletionFn $ \rc aclPtr statPtr _ ->
    fn =<< (onZOK rc $ do
      aclList <- toAclList aclPtr
      stat    <- toStat statPtr
      return (aclList, stat))

wrapDataCompletion :: DataCompletion -> IO (FunPtr CDataCompletionFn)
wrapDataCompletion fn =
  c_dataCompletionFn $ \rc valPtr valLen statPtr _ ->
    fn =<< (onZOK rc $ do
      stat <- toStat statPtr
      if (valLen == -1)
        then return (Nothing, stat)
        else fmap (\s -> (Just s, stat)) (B.packCStringLen (valPtr, fromIntegral valLen)))

wrapStringCompletion :: StringCompletion -> IO (FunPtr CStringCompletionFn)
wrapStringCompletion fn =
  c_stringCompletionFn $ \rc strPtr _ ->
    fn =<< (onZOK rc $ do
      peekCString strPtr)

wrapStringsCompletion :: StringsCompletion -> IO (FunPtr CStringsCompletionFn)
wrapStringsCompletion fn =
  c_stringsCompletionFn $ \rc strvPtr _ ->
    fn =<< (onZOK rc (toStringList strvPtr))

wrapVoidCompletion :: VoidCompletion -> IO (FunPtr CVoidCompletionFn)
wrapVoidCompletion fn =
  c_voidCompletionFn $ \rc _ -> (fn =<< onZOK rc (return ()))

foreign import ccall safe "wrapper"
  c_watcherFn :: CWatcherFn
                 -> IO (FunPtr CWatcherFn)

foreign import ccall safe "wrapper"
  c_dataCompletionFn :: CDataCompletionFn
                        -> IO (FunPtr CDataCompletionFn)

foreign import ccall safe "wrapper"
  c_stringsCompletionFn :: CStringsCompletionFn
                        -> IO (FunPtr CStringsCompletionFn)

foreign import ccall safe "wrapper"
  c_stringCompletionFn :: CStringCompletionFn
                       -> IO (FunPtr CStringCompletionFn)

foreign import ccall safe "wrapper"
  c_aclCompletionFn :: CAclCompletionFn
                    -> IO (FunPtr CAclCompletionFn)

foreign import ccall safe "wrapper"
  c_voidCompletionFn :: CVoidCompletionFn
                     -> IO (FunPtr CVoidCompletionFn)

foreign import ccall safe "zookeeper.h zookeeper_init"
  c_zookeeperInit :: CString
                  -> FunPtr CWatcherFn
                  -> CInt
                  -> Ptr CClientID
                  -> Ptr ()
                  -> CInt
                  -> IO (Ptr CZHandle)

foreign import ccall safe "zookeeper.h zookeeper_close"
  c_zookeeperClose :: Ptr CZHandle -> IO ()

foreign import ccall safe "zookeeper.h zoo_set_watcher"
  c_zooSetWatcher :: Ptr CZHandle -> FunPtr CWatcherFn -> IO ()

foreign import ccall safe "zookeeper.h zoo_acreate"
  c_zooACreate :: Ptr CZHandle -> CString -> CString -> CInt -> Ptr CAclVec -> CInt -> FunPtr CStringCompletionFn -> Ptr () -> IO CInt

foreign import ccall safe "zookeeper.h zoo_delete"
  c_zooDelete :: Ptr CZHandle -> CString -> CInt -> IO CInt

foreign import ccall safe "zookeeper.h zoo_wexists"
  c_zooWExists :: Ptr CZHandle -> CString -> FunPtr CWatcherFn -> Ptr () -> Ptr CStat -> IO CInt

foreign import ccall safe "zookeeper.h zoo_state"
  c_zooState :: Ptr CZHandle -> IO CInt

foreign import ccall safe "zookeeper.h zoo_client_id"
  c_zooClientId :: Ptr CZHandle -> IO (Ptr CClientID)

foreign import ccall safe "zookeeper.h zoo_recv_timeout"
  c_zooRecvTimeout :: Ptr CZHandle -> IO CInt

foreign import ccall safe "zookeeper.h zoo_add_auth"
  c_zooAddAuth :: Ptr CZHandle -> CString -> CString -> CInt -> FunPtr CVoidCompletionFn -> Ptr () -> IO CInt

foreign import ccall safe "zookeeper.h is_unrecoverable"
  c_isUnrecoverable :: Ptr CZHandle -> IO CInt

foreign import ccall safe "zookeeper.h zoo_set_debug_level"
  c_zooSetDebugLevel :: CInt -> IO ()

foreign import ccall safe "zookeeper.h zoo_aget_acl"
  c_zooAGetAcl :: Ptr CZHandle -> CString -> FunPtr CAclCompletionFn -> Ptr () -> IO CInt

foreign import ccall safe "zookeeper.h zoo_set_acl"
  c_zooSetAcl :: Ptr CZHandle -> CString -> CInt -> Ptr CAclVec -> IO CInt

foreign import ccall safe "zookeeper.h zoo_awget"
  c_zooAWGet :: Ptr CZHandle -> CString -> FunPtr CWatcherFn -> Ptr () -> FunPtr CDataCompletionFn -> Ptr () -> IO CInt

foreign import ccall safe "zookeeper.h zoo_set2"
  c_zooSet2 :: Ptr CZHandle -> CString -> CString -> CInt -> CInt -> Ptr CStat -> IO CInt

foreign import ccall safe "zookeeper.h zoo_awget_children"
  c_zooAWGetChildren :: Ptr CZHandle -> CString -> FunPtr CWatcherFn -> Ptr () -> FunPtr CStringsCompletionFn -> Ptr () -> IO CInt

foreign import ccall safe "zookeeper.h &ZOO_CREATOR_ALL_ACL"
  c_zooCreatorAclAll :: Ptr CAclVec

foreign import ccall safe "zookeeper.h &ZOO_OPEN_ACL_UNSAFE"
  c_zooOpenAclUnsafe :: Ptr CAclVec

foreign import ccall safe "zookeeper.h &ZOO_READ_ACL_UNSAFE"
  c_zooReadAclUnsafe :: Ptr CAclVec
