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

module Database.Zookeeper.Types
       ( -- * Public Types
         Acl (..)
       , Perm (..)
       , Stat (..)
       , Event (..)
       , State (..)
       , Scheme
       , AclList (..)
       , Timeout
       , Version
       , ClientID (..)
       , ZLogLevel (..)
       , Zookeeper (..)
       , CreateFlag (..)
         -- * Error codes
       , ZKError (..)
         -- * Public Callbacks
       , Watcher
       , AclCompletion
       , DataCompletion
       , VoidCompletion
       , StringCompletion
       , StringsCompletion
         -- * Low-level Types
       , CAcl
       , CStat
       , CAclVec
       , CStrVec
       , CZHandle
       , CClientID
         -- * Low-level Callbacks
       , CWatcherFn
       , CAclCompletionFn
       , CVoidCompletionFn
       , CDataCompletionFn
       , CStringCompletionFn
       , CStringsCompletionFn
       ) where

import           Foreign
import           Foreign.C
import qualified Data.ByteString as B

newtype Zookeeper = Zookeeper (Ptr CZHandle)

newtype ClientID = ClientID (Ptr CClientID)

type Timeout = Int

type Version = Int

type Scheme = String

-- | Log levels
data ZLogLevel = ZLogError
               | ZLogWarn
               | ZLogInfo
               | ZLogDebug

-- | Zookeeper error codes
data ZKError = ApiError
             | NoAuthError
             | NoNodeError
             | SystemError
             | ClosingError
             | NothingError
             | NotEmptyError
             | AuthFailedError
             | BadVersionError
             | InvalidACLError
             | NodeExistsError
             | MarshallingError
             | BadArgumentsError
             | InvalidStateError
             | SessionMovedError
             | UnimplmenetedError
             | ConnectionLossError
             | SessionExpiredError
             | InvalidCallbackError
             | OperationTimeoutError
             | DataInconsistencyError
             | RuntimeInconsistencyError
             | NoChildrenForEphemeralsError
             | UnknownError Int
             deriving (Eq, Show)

-- | The stat of a znode
data Stat = Stat { statCzxId           :: Int64
                 -- ^ The zxid of the change that caused this node to be created
                 , statMzxId           :: Int64
                 -- ^ The zxid of the change that last modified this znode
                 , statPzxId           :: Int64
                 -- ^ The zxid of the change that last modified children of this znode
                 , statCreatetime      :: Int64
                 -- ^ The time in milliseconds from epoch when this znode was created
                 , statModifytime      :: Int64
                 -- ^ The time in milliseconds from epoch when this znode was last modified
                 , statVersion         :: Int32
                 -- ^ The number of changes to the data of this znode
                 , statChildrenVersion :: Int32
                 -- ^ The number of changes to the children of this znode
                 , statAclVersion      :: Int32
                 -- ^ The number of changes to the acl of this znode
                 , statDataLength      :: Int32
                 -- ^ The length of the data field of this znode
                 , statNumChildren     :: Int32
                 -- ^ The number of children of this znode
                 , statEphemeralOwner  :: Maybe Int64
                 -- ^ The session id of the owner of this znode if the znode is an ephemeral node
                 }
          deriving (Eq, Show)

-- | Zookeeper event type (the *_EVENT flags)
data Event = ChildEvent
           | CreatedEvent
           | DeletedEvent
           | ChangedEvent
           | SessionEvent
           | NotWatchingEvent
           | UnknownEvent Int
           -- ^ Used when the underlying C API has returned an unknown event type
           deriving (Eq, Show)

-- | Zookeeper connection state (the *_STATE flags)
data State = ExpiredSessionState
           | AuthFailedState
           | ConnectingState
           | AssociatingState
           | ConnectedState
           | UnknownState Int
           -- ^ Used when the underlying C API has returned an unknown status code
           deriving (Eq, Show)

-- | The permission bits of a ACL
data Perm = CanRead
          -- ^ Can read data and enumerate its children
          | CanAdmin
          -- ^ Can modify permissions bits
          | CanWrite
          -- ^ Can modify data
          | CanCreate
          -- ^ Can create children
          | CanDelete
          -- ^ Can remove
          deriving (Eq, Show)

-- | A single ACL
data Acl = Acl { aclScheme :: String
               -- ^ The ACL scheme (e.g. "ip", "world", "digest"
               , aclId     :: String
               -- ^ The schema-depent ACL identity (e.g. scheme="ip", id="127.0.0.1")
               , aclFlags  :: [Perm]
               -- ^ The [non empty] list of permissions
               }
         deriving (Eq, Show)

-- | ACL list
data AclList = List [Acl]
             -- ^ A [non empty] list of ACLs
             | CreatorAll
             -- ^ This gives the creators authentication id's all permissions
             | OpenAclUnsafe
             -- ^ This is a completely open ACL
             | ReadAclUnsafe
             -- ^ This ACL gives the world the ability to read
             deriving (Eq, Show)

-- | The optional flags you may use to create a node
data CreateFlag = Sequence
                -- ^ A unique monotonically increasing sequence number is appended to the path name
                | Ephemeral
                -- ^ The znode will automatically get removed if the client session goes away
                deriving (Eq, Show)

-- | The watcher function, which allows you to get notified about
-- zookeeper events.
type Watcher = Event
             -- ^ The event that has triggered the watche
             -> State
             -- ^ The connection state
             -> Maybe B.ByteString
             -- ^ The znode for which the watched is triggered
             -> IO ()

-- | Callback function for `wrapDataCompletion', which you can use
-- with c_zooAWGet function. You probably don't need this.
type DataCompletion = Either ZKError (Maybe B.ByteString, Stat) -> IO ()

-- | Callback function for `wrapStringsCompletion', which you can use
-- with c_zooAWGetChildren function. You probably don't need this.
type StringsCompletion = Either ZKError [String] -> IO ()

-- | Callback function for `wrapStringCompletion', which you can use
-- with c_zooACreate function. You probably don't need this.
type StringCompletion = Either ZKError String -> IO ()

-- | Callback function for `wrapAclCompletion', which you can use with
-- c_zooAGetAcl function. You probably don't need this.
type AclCompletion = Either ZKError (AclList, Stat) -> IO ()

-- | Callback function for `wrapVoidCompletion', which you can use
-- with c_zooAddAuth function. You probably don't need this.
type VoidCompletion = Either ZKError () -> IO ()

data CAcl
data CStat
data CAclVec
data CStrVec
data CZHandle
data CClientID

type CWatcherFn = Ptr CZHandle
                -> CInt
                -> CInt
                -> CString
                -> Ptr ()
                -> IO ()

type CVoidCompletionFn = CInt
                      -> Ptr ()
                      -> IO ()

type CDataCompletionFn = CInt
                      -> CString
                      -> CInt
                      -> Ptr CStat
                      -> Ptr ()
                      -> IO ()

type CStringsCompletionFn = CInt
                         -> Ptr CStrVec
                         -> Ptr ()
                         -> IO ()

type CStringCompletionFn = CInt
                        -> CString
                        -> Ptr ()
                        -> IO ()

type CAclCompletionFn = CInt
                     -> Ptr CAclVec
                     -> Ptr CStat
                     -> Ptr ()
                     -> IO ()
     
