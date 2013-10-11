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

-- | The public interface that provides access to the zookeeper
-- c-library
--
-- This module requires linking against the `zookeeper_mt' lib as it
-- uses async functions. However, all functions in this library are
-- synchronous, from the callers perspective. As such, make sure you
-- link using the -thread [GHC].
--
-- The following example lists all children of the ''/'' znode:
--
-- >  import Database.Zookeeper
-- >
-- >  watcher zh _ ConnectedState _ = getChildren zh "/" Nothing >>= print
-- >  watcher _ _ _ _               = return ()
-- >
-- >  withZookeeper "localhost:2181" 5000 (Just watcher) Nothing $ \zh -> do
-- >    threadDelay 50000
module Database.Zookeeper where

import           Foreign
import           Foreign.C
import qualified Data.ByteString as B
import           Control.Exception
import           Control.Concurrent.MVar
import           Database.Zookeeper.CApi
import           Database.Zookeeper.Types

-- | Connects to the zookeeper cluster. This function may throw an
-- exception if a valid zookeeper handle could be created
withZookeeper :: String
              -- ^ The zookeeper endpoint to connect to. This is given
              -- as-is to the underlying C API. Briefly, host:port
              -- separated by comma. At the end, you may define an
              -- optional chroot, like the following:
              --   localhost:2181,localhost:2182/foobar
              -> Timeout
              -- ^ The session timeout (milliseconds)
              -> Maybe Watcher
              -- ^ The global watcher function. When notifications are
              -- triggered this function will be invoked
              -> Maybe ClientID
              -- ^ The id of a previously established session that
              -- this client will be reconnecting to
              -> (Zookeeper -> IO a)
              -- ^ The main loop. The session is terminated when this
              -- function exists (successfully or not)
              -> IO a
withZookeeper endpoint timeout watcher clientId io = do
  withCString endpoint $ \strPtr -> mask $ \restore -> do
    cWatcher <- wrapWatcher watcher
    zh       <- throwIfNull "zookeeper_init" $ c_zookeeperInit strPtr cWatcher (fromIntegral timeout) cClientIdPtr nullPtr 0
    value    <- (restore $ io (Zookeeper zh)) `onException` c_zookeeperClose zh
    c_zookeeperClose zh
    return value
    where
      cClientIdPtr = case clientId of
                       Nothing             -> nullPtr
                       Just (ClientID ptr) -> ptr

-- | Sets [or redefines] the watcher function
setWatcher :: Zookeeper
           -- ^ Zookeeper handle
           -> Watcher
           -- ^ New watch function to register
           -> IO ()
setWatcher (Zookeeper zptr) watcher = c_zooSetWatcher zptr =<< wrapWatcher (Just watcher)

-- | The current state of this session
getState :: Zookeeper
         -- ^ Zookeeper handle
         -> IO State
         -- ^ Current state
getState (Zookeeper zh) = fmap toState $ c_zooState zh

-- | The client session id, only valid if the session currently
-- connected [ConnectedState]
getClientId :: Zookeeper -> IO ClientID
getClientId (Zookeeper zh) = fmap ClientID $ c_zooClientId zh

-- | The timeout for this session, only valid if the session is
-- currently connected [ConnectedState]
getRecvTimeout :: Zookeeper -> IO Int
getRecvTimeout (Zookeeper zh) = fmap fromIntegral $ c_zooRecvTimeout zh

-- | Sets the debugging level for the c-library
setDebugLevel :: ZLogLevel -> IO ()
setDebugLevel = c_zooSetDebugLevel . fromLogLevel

-- | Checks if the current zookeeper connection state can't be recovered [== True].
isUnrecoverable :: Zookeeper -> IO Bool
isUnrecoverable (Zookeeper zh) = fmap ((== InvalidStateError) . toZKError) (c_isUnrecoverable zh)

-- | Creates a znode
create :: Zookeeper
       -- ^ Zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> Maybe B.ByteString
       -- ^ The data to be stored in the znode
       -> AclList
       -- ^ The initial ACL of the node. The ACL must not be empty
       -> [CreateFlag]
       -- ^ Optional, may be empty
       -> IO (Either ZKError String)
       -- ^ On error the user may observe the following values:
       --     * Left NoNodeError                  -> the parent znode does not exit
       --
       --     * Left NodeExistsError              -> the node already exists
       --
       --     * Left NoAuthError                  -> client does not have permission
       --
       --     * Left NoChildrenForEphemeralsError -> cannot create children of ephemeral nodes
       --
       --     * Left BadArgumentsError            -> invalid input params
       --
       --     * Left InvalidStateError            -> Zookeeper state is either `ExpiredSessionState' or `AuthFailedState'
create (Zookeeper zh) path mvalue acls flags =
  withCString path $ \pathPtr ->
    maybeUseAsCStringLen mvalue $ \(valuePtr, valueLen) ->
      withAclList acls $ \aclPtr -> do
        mvar   <- newEmptyMVar
        cStrFn <- wrapStringCompletion (putMVar mvar)
        rc     <- c_zooACreate zh pathPtr valuePtr (fromIntegral valueLen) aclPtr (fromCreateFlags flags) cStrFn nullPtr
        whenZOK rc (takeMVar mvar)
    where
      maybeUseAsCStringLen Nothing f  = f (nullPtr, -1)
      maybeUseAsCStringLen (Just s) f = B.useAsCStringLen s f

-- | Delete a znode in zookeeper
delete :: Zookeeper
       -- ^ Zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> Maybe Version
       -- ^ The expected version of the znode. The function will fail
       -- if the actual version of the znode does not match the
       -- expected version. If `Nothing' is given the version check
       -- will not take place
       -> IO (Either ZKError ())
       -- ^ If an error occurs, you may observe the following values:
       --     * Left NoNodeError       -> znode does not exist
       --
       --     * Left NoAuthError       -> client does not have permission
       --
       --     * Left BadVersionError   -> expected version does not match actual version
       --
       --     * Left BadArgumentsError -> invalid input parameters
       --
       --     * Left InvalidStateError -> Zookeeper state is either `ExpiredSessionState' or `AuthFailedState'
delete (Zookeeper zh) path mversion =
  withCString path $ \pathPtr ->
    tryZ (c_zooDelete zh pathPtr (maybe (-1) fromIntegral mversion)) (return ())

-- ^ Checks the existence of a znode
exists :: Zookeeper
       -- ^ Zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> Maybe Watcher
       -- ^ This is set even if the znode does not exist. This allows
       -- users to watch znodes to appear
       -> IO (Either ZKError Stat)
       -- ^ If an error occurs, you may observe the following values:
       --     * Left NoNodeError       -> znode does not exist
       --
       --     * Left NoAuthError       -> client does not have permission
       --
       --     * Left BadArgumentsError -> invalid input parameters
       --
       --     * Left InvalidStateError -> Zookeeper state is either `ExpiredSessionState' or `AuthFailedState'
exists (Zookeeper zh) path mwatcher =
  withCString path $ \pathPtr ->
    allocaStat $ \statPtr -> do
      cWatcher <- wrapWatcher mwatcher
      tryZ (c_zooWExists zh pathPtr cWatcher nullPtr statPtr) (toStat statPtr)

-- | Lists the children of a znode
getChildren :: Zookeeper
            -- ^ Zookeeper handle
            -> String
            -- ^ The name of the znode expressed as a file name with slashes
            -- separating ancestors of the znode
            -> Maybe Watcher
            -- ^ The watch to be set at the server to notify the user
            -- if the node changes
            -> IO (Either ZKError [String])
            -- ^ On failure the user may observe the following values:
            --
            --     * Left NoNodeError       -> znode does not exit
            --
            --     * Left NoAuthError       -> client does not have permission
            --
            --     * Left BadArgumentsError -> invalid input parameters
            --
            --     * Left InvalidStateError -> Zookeeper state is either `ExpiredSessionState' or `AuthFailedState'
getChildren (Zookeeper zh) path mwatcher = do
  withCString path $ \pathPtr -> do
    cWatcher <- wrapWatcher mwatcher
    mvar     <- newEmptyMVar
    cStrFn   <- wrapStringsCompletion (putMVar mvar)
    rc       <- c_zooAWGetChildren zh pathPtr cWatcher nullPtr cStrFn nullPtr
    whenZOK rc (takeMVar mvar)

-- | Gets the data associated with a znode
get :: Zookeeper
    -- ^ The Zookeeper handle
    -> String
    -- ^ The name of the znode expressed as a file name with slashes
    -- separating ancestors of the znode
    -> Maybe Watcher
    -- ^ When provided, a watch will be set at the server to notify
    -- the client if the node changes
    -> IO (Either ZKError (Maybe B.ByteString, Stat))
get (Zookeeper zh) path mwatcher =
  withCString path $ \pathPtr -> do
    cWatcher <- wrapWatcher mwatcher
    mvar     <- newEmptyMVar
    cDataFn  <- wrapDataCompletion (putMVar mvar)
    rc       <- c_zooAWGet zh pathPtr cWatcher nullPtr cDataFn nullPtr
    whenZOK rc (takeMVar mvar)

-- | Sets the data associated with a znode
set :: Zookeeper
    -- ^ Zookeeper handle
    -> String
    -- ^ The name of the znode expressed as a file name with slashes
    -- separating ancestors of the znode
    -> Maybe B.ByteString
    -- ^ The data to set on this znode
    -> Maybe Version
    -- ^ The expected version of the znode. The function will fail
    -- if the actual version of the znode does not match the
    -- expected version. If `Nothing' is given the version check
    -- will not take place
    -> IO (Either ZKError Stat)
    -- ^ On failure you may observe the following values:
    --
    --     * Left NoNodeError       -> znode does not exist
    --
    --     * Left NoAuthError       -> client does not have permission
    --
    --     * Left BadVersionError   -> expected version does not match actual version
    --
    --     * Left BadArgumentsError -> invalid input parameters
    --
    --     * Left InvalidStateError -> Zookeeper handle is either `ExpiredSessionState' or `AuthFailedState'
set (Zookeeper zh) path mdata version =
  withCString path $ \pathPtr ->
    allocaStat $ \statPtr -> do
      maybeUseAsCStringLen mdata $ \(dataPtr, dataLen) -> do
        rc <- c_zooSet2 zh pathPtr dataPtr (fromIntegral dataLen) (maybe (-1) fromIntegral version) statPtr
        onZOK rc (toStat statPtr)
    where
      maybeUseAsCStringLen Nothing f  = f (nullPtr, -1)
      maybeUseAsCStringLen (Just s) f = B.useAsCStringLen s f

-- | Sets the acl associated with a node. This operation is not
-- recursive on the children
setAcl :: Zookeeper
       -- ^ Zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> Maybe Version
       -- ^ The expected version of the znode. The function will fail
       -- if the actual version of the znode does not match the
       -- expected version. If `Nothing' is given the version check
       -- will not take place
       -> AclList
       -- ^ The ACL list to be set on the znode. The ACL must not be empty
       -> IO (Either ZKError ())
       -- ^ On failure the following values may be returned:
       --
       --     * Left NoNodeError       -> the znode does not exist
       --
       --     * Left NoAuthError       -> client does not have permission
       --
       --     * Left InvalidACLError   -> invalid acl specified
       --
       --     * Left BadVersionError   -> expected version does not match actual version
       --
       --     * Left InvalidStateError -> Zookeeper handle is either `ExpiredSessionState' or `AuthFailedState'
setAcl (Zookeeper zh) path version acls =
  withCString path $ \pathPtr ->
    withAclList acls $ \aclPtr -> do
      rc <- c_zooSetAcl zh pathPtr (maybe (-1) fromIntegral version) aclPtr
      onZOK rc $ return ()

-- | Gets the acl associated with a node
getAcl :: Zookeeper
       -- ^ The zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> IO (Either ZKError (AclList, Stat))
       -- ^ On failure the user may observe the following values:
       --
       --     * Left NoNodeError       -> znode does not exit
       --
       --     * Left NoAuthError       -> client does not have permission
       --
       --     * Left BadArgumentsError -> invalid input parameters
getAcl (Zookeeper zh) path =
  withCString path $ \pathPtr -> do
    mvar   <- newEmptyMVar
    cAclFn <- wrapAclCompletion (putMVar mvar)
    rc     <- c_zooAGetAcl zh pathPtr cAclFn nullPtr
    whenZOK rc (takeMVar mvar)

-- | Specify application credentials
--
-- The application calls this function to specify its credentials for
-- purposes of authentication. The server will use the security
-- provider specified by the scheme parameter to authenticate the
-- client connection. If the authentication request has failed:
--
--   * the server connection is dropped;
--
--   * the watcher is called witht AuthFailedState value as the state
--   parameter;
addAuth :: Zookeeper
        -- ^ Zookeeper handle
        -> Scheme
        -- ^ Scheme id of the authentication scheme. Natively supported:
        --
        --     * "digest" -> password based authentication;
        -> B.ByteString
        -- ^ Applicaton credentials. The actual value depends on the scheme
        -> IO (Either ZKError ())
        -- ^ On error the following values may be observed:
        --
        --     * Left AuthFailedError     -> authenticaton failed
        --
        --     * Left InvalidStateError   -> Zookeeper handle is either `ExpiredSessionState' or `AuthFailedState'
        --
        --     * Left BadArgumentsError   -> invalid input parameters
addAuth (Zookeeper zh) scheme cert =
  withCString scheme $ \schemePtr ->
    B.useAsCStringLen cert $ \(certPtr, certLen) -> do
      mvar    <- newEmptyMVar
      cVoidFn <- wrapVoidCompletion (putMVar mvar)
      rc      <- c_zooAddAuth zh schemePtr certPtr (fromIntegral certLen) cVoidFn nullPtr
      whenZOK rc (takeMVar mvar)
