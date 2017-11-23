data Client    = Client { clientName :: String
                        , subs       :: HashTable Int (Chan String)
                        , joinId     :: Int
                        }
data Clients   = Clients { lastClientId   :: Int
                         , theClients     :: HashTable Int Client
                         , clientsNames   :: HashTable String Int
                         }
data ChatRoom  = ChatRoom Int (Chan String)
data ChatRooms = ChatRooms { chatRoomFromId     :: HashTable Int ChatRoom
                           , chatRoomIdFromName :: HashTable String Int
                           , numberOfChatRooms  :: Int  
                           }
