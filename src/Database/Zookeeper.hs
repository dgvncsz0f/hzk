{-# LANGUAGE Safe          #-}
{-# LANGUAGE TupleSections #-}

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

--------------------------------------------------------------------------------
-- |
-- Module        : Database.Zookeeper
-- Copyright     : (C) 2013 Diego Souza
-- License       : BSD-style (see the file LICENSE)
--
-- Maintainer    : Diego Souza <dsouza@c0d3.xxx>
-- Stability     : experimental
--
-- Zookeeper client library
--------------------------------------------------------------------------------
module Database.Zookeeper
       ( -- * Description
         -- $description

         -- * Example
         -- $example

         -- * Notes
         -- $notes

         -- * Connection
         addAuth
       , setWatcher
       , withZookeeper

         -- * Configuration/State
       , getState
       , getClientId
       , setDebugLevel
       , getRecvTimeout

         -- * Reading
       , get
       , exists
       , getAcl
       , getChildren
       , ownsEphemeral

         -- * Writing
       , set
       , create
       , delete
       , setAcl

         -- * Types
       , Scheme
       , Timeout
       , Watcher
       , ClientID ()
       , Zookeeper ()

       , Acl (..)
       , Perm (..)
       , Stat (..)
       , Event (..)
       , State (..)
       , AclList (..)
       , Version
       , ZLogLevel (..)
       , CreateFlag (..)

         -- ** Error values
       , ZKError (..)
       ) where

import           Foreign.C
import           Foreign.Safe
import           Control.Monad
import qualified Data.ByteString as B
import           Control.Exception
import           Database.Zookeeper.CApi
import           Database.Zookeeper.Types

-- | Connects to the zookeeper cluster. This function may throw an
-- exception if a valid zookeeper handle could not be created.
--
-- The connection is terminated right before this function returns.
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
              -- function exits (successfully or not)
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

-- | Test if the ephemeral node has been created by this
-- clientid. This function shall return False if the node is not
-- ephemeral or is not owned by this clientid.
ownsEphemeral :: ClientID -> Stat -> IO Bool
ownsEphemeral (ClientID clientPtr) stat = do
  uid <- toClientId clientPtr
  return (statEphemeralOwner stat == Just uid)

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
create (Zookeeper zh) path mvalue acls flags =
  withCString path $ \pathPtr ->
    maybeUseAsCStringLen mvalue $ \(valuePtr, valueLen) ->
      withAclList acls $ \aclPtr ->
        allocaBytes pathlen $ \newPathPtr -> do
          rc <- c_zooCreate zh pathPtr valuePtr (fromIntegral valueLen) aclPtr (fromCreateFlags flags) newPathPtr (fromIntegral pathlen)
          if (isZOK rc)
            then fmap Right (peekCString newPathPtr)
            else return (Left $ toZKError rc)
    where
      pathlen = length path + 11
      maybeUseAsCStringLen Nothing f  = f (nullPtr, -1)
      maybeUseAsCStringLen (Just s) f = B.useAsCStringLen s f

-- | Delete a znode in zookeeper (synchronous)
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
delete (Zookeeper zh) path mversion =
  withCString path $ \pathPtr ->
    tryZ (c_zooDelete zh pathPtr (maybe (-1) fromIntegral mversion)) (return ())

-- ^ | Checks the existence of a znode (synchronous)
exists :: Zookeeper
       -- ^ Zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> Maybe Watcher
       -- ^ This is set even if the znode does not exist. This allows
       -- users to watch znodes to appear
       -> IO (Either ZKError Stat)
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
getChildren (Zookeeper zh) path mwatcher =
  withCString path $ \pathPtr ->
    allocaStrVec $ \strVecPtr -> do
      cWatcher <- wrapWatcher mwatcher
      rc       <- c_zooWGetChildren zh pathPtr cWatcher nullPtr strVecPtr
      if (isZOK rc)
        then fmap Right $ toStringList strVecPtr
        else return (Left $ toZKError rc)

-- | Gets the data associated with a znode (asynchronous)
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
  withCString path $ \pathPtr ->
    allocaBytes buffSize $ \dataPtr ->
      allocaStat $ \statPtr ->
        alloca $ \buffSizePtr -> do
          poke buffSizePtr (fromIntegral buffSize)
          cWatcher <- wrapWatcher mwatcher
          rc       <- c_zooWGet zh pathPtr cWatcher nullPtr dataPtr buffSizePtr statPtr
          dataSz   <- peek buffSizePtr
          case (isZOK rc, fromIntegral dataSz) of
            (True, -1) -> return . Right =<< fmap (Nothing ,) (toStat statPtr)
            (True, sz) -> return . Right =<< liftM2 (,) (fmap Just $ B.packCStringLen (dataPtr, sz)) (toStat statPtr)
            (False, _) -> return (Left $ toZKError rc)
    where
      buffSize = 1024 * 1024

-- | Sets the data associated with a znode (synchronous)
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
set (Zookeeper zh) path mdata version =
  withCString path $ \pathPtr ->
    allocaStat $ \statPtr ->
      maybeUseAsCStringLen mdata $ \(dataPtr, dataLen) -> do
        rc <- c_zooSet2 zh pathPtr dataPtr (fromIntegral dataLen) (maybe (-1) fromIntegral version) statPtr
        onZOK rc (toStat statPtr)
    where
      maybeUseAsCStringLen Nothing f  = f (nullPtr, -1)
      maybeUseAsCStringLen (Just s) f = B.useAsCStringLen s f

-- | Sets the acl associated with a node. This operation is not
-- recursive on the children. See 'getAcl' for more information (synchronous)
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
setAcl (Zookeeper zh) path version acls =
  withCString path $ \pathPtr ->
    withAclList acls $ \aclPtr -> do
      rc <- c_zooSetAcl zh pathPtr (maybe (-1) fromIntegral version) aclPtr
      onZOK rc $ return ()

-- | Gets the acl associated with a node (asynchronous). Unexpectedly, 'setAcl' and
-- 'getAcl' are not symmetric:
--
-- > setAcl zh path Nothing OpenAclUnsafe
-- > getAcl zh path (..) -- yields AclList instead of OpenAclUnsafe
getAcl :: Zookeeper
       -- ^ The zookeeper handle
       -> String
       -- ^ The name of the znode expressed as a file name with slashes
       -- separating ancestors of the znode
       -> IO (Either ZKError (AclList, Stat))
getAcl (Zookeeper zh) path =
  withCString path $ \pathPtr ->
    allocaAclVec $ \aclVecPtr ->
      allocaStat $ \statPtr -> do
        rc <- c_zooGetAcl zh pathPtr aclVecPtr statPtr
        if (isZOK rc)
          then fmap Right $ liftM2 (,) (toAclList aclVecPtr) (toStat statPtr)
          else return (Left $ toZKError rc)

-- | Specify application credentials (asynchronous)
--
-- The application calls this function to specify its credentials for
-- purposes of authentication. The server will use the security
-- provider specified by the scheme parameter to authenticate the
-- client connection. If the authentication request has failed:
--
--   * the server connection is dropped;
--
--   * the watcher is called with AuthFailedState value as the state
--   parameter;
addAuth :: Zookeeper
        -- ^ Zookeeper handle
        -> Scheme
        -- ^ Scheme id of the authentication scheme. Natively supported:
        --
        --     * ''digest'' -> password authentication;
        --
        --     * ''ip''     -> client's IP address;
        --
        --     * ''host''   -> client's hostname;
        -> B.ByteString
        -- ^ Applicaton credentials. The actual value depends on the scheme
        -> (Either ZKError () -> IO ())
        -- ^ The callback function
        -> IO ()
addAuth (Zookeeper zh) scheme cert callback =
  withCString scheme $ \schemePtr ->
    B.useAsCStringLen cert $ \(certPtr, certLen) -> do
      cVoidFn <- wrapVoidCompletion callback
      rc      <- c_zooAddAuth zh schemePtr certPtr (fromIntegral certLen) cVoidFn nullPtr
      unless (isZOK rc) (callback $ Left (toZKError rc))

-- $description
--
-- This library provides haskell bindings for zookeeper c-library (mt).

-- $example
--
-- The following snippet creates a ''/foobar'' znode, then it lists and
-- prints all children of the root znode:
-- 
-- > module Main where
-- >
-- > import Database.Zookeeper
-- > import Control.Concurrent
-- >
-- > main :: IO ()
-- > main = do
-- >   mvar <- newEmptyMVar
-- >   withZookeeper "localhost:2181" 1000 (Just $ watcher mvar) Nothing $ \_ -> do
-- >     takeMVar mvar >>= print
-- >     where
-- >       watcher mvar zh _ ConnectedState _ = do
-- >         void $ create zh "/foobar" Nothing OpenAclUnsafe []
-- >         getChildren zh "/" Nothing >>= putMVar mvar

-- $notes
--   * Watcher callbacks must never block;
--
--   * Make sure you link against zookeeper_mt;
--
--   * Make sure you are using the `threaded' (GHC) runtime;
-- 
--   * The connection is closed right before the 'withZookeeper'
--     terminates;
--
--   * There is no yet support for multi operations (executing a
--     series of operations atomically);
