module Main where

import Network.Socket
import System.IO
import System.Environment
import Control.Exception
import Control.Monad.Fix (fix)
import Control.Concurrent.ParallelIO.Local
import Control.Concurrent.MVar
import Control.Concurrent
import Data.List
import Data.List.Split
import qualified Data.HashTable.IO as H
import Control.Monad (when, unless)

import ChatHelpers

main :: IO ()
main = do
    [port] <- getArgs
    sock <- socket AF_INET Stream 0                            -- create socket
    setSocketOption sock ReuseAddr 1                           -- make socket immediately reusable.
    bind sock (SockAddrInet (toEnum $ read port) iNADDR_ANY)   -- listen on TCP port given by user.
    let nbThreads = 5
    listen sock (nbThreads*2)                                  -- queue of 10 connections max
    killedChan <- newChan
    htSI           <- H.new :: IO (HashTable String Int)
    htIC           <- H.new :: IO (HashTable Int ChatRoom)
    htClients      <- H.new :: IO (HashTable Int Client)
    htClientsNames <- H.new :: IO (HashTable String Int)
    let nbCR = 0
    chatRooms <- newMVar (ChatRooms {chatRoomFromId=htIC, chatRoomIdFromName=htSI, numberOfChatRooms=nbCR})
    clients <- newMVar (Clients 0 htClients htClientsNames)
    withPool nbThreads $
        \pool -> parallel_ pool (replicate nbThreads (server sock port killedChan clients chatRooms))
    clog "Server killed"

server :: Socket -> String -> Chan Bool -> MVar Clients -> MVar ChatRooms -> IO ()
server sock port killedChan clients chatrooms = do
    clog "Waiting for connection"
    conn <- try (accept sock) :: IO (Either SomeException (Socket, SockAddr))  -- try to accept a connection and handle it
    case conn of
        Left  _    -> clog "Socket is now closed. Exiting."
        Right conn -> do
            clog "Client connected!"
            runClient conn sock port killedChan clients chatrooms
            server sock port killedChan clients chatrooms

loopClient :: Handle -> Socket -> String -> Chan Bool -> MVar Clients -> MVar ChatRooms -> [Int] -> IO ()
loopClient hdl originalSocket port killedChan clients chatrooms joinIds = do
    (kill, timedOut, input) <- waitForInput hdl killedChan 0 joinIds clients
    when (timedOut) (clog "Client timed out")
    when (kill || timedOut) (return ())
    let commandAndArgs = splitOn " " input
    let command = head commandAndArgs
    let args = intercalate " " $ tail commandAndArgs
    case command of
        "KILL_SERVICE"    -> do
            writeChan killedChan True
            threadDelay 200000 -- 200ms
            killService originalSocket
        "HELO"            -> do
            helo hdl args port
            loopClient hdl originalSocket port killedChan clients chatrooms joinIds
        "JOIN_CHATROOM:"  -> do
            (error, id) <- join hdl args port clients chatrooms
            if error then return ()
            else do
                if id `elem` joinIds then loopClient hdl originalSocket port killedChan clients chatrooms joinIds
                else loopClient hdl originalSocket port killedChan clients chatrooms (id:joinIds)
        "LEAVE_CHATROOM:" -> do
            (error, id) <- leave hdl args clients
            if error then return ()
            else do
                loopClient hdl originalSocket port killedChan clients chatrooms (delete id joinIds)
        "DISCONNECT:"     -> do
            error <- disconnect hdl args clients
            unless error (loopClient hdl originalSocket port killedChan clients chatrooms joinIds)
        "CHAT:"           -> do
            error <- chat hdl args clients
            unless error (loopClient hdl originalSocket port killedChan clients chatrooms joinIds)
        _                 -> otherCommand hdl input


runClient :: (Socket, SockAddr) -> Socket -> String -> Chan Bool -> MVar Clients -> MVar ChatRooms -> IO ()
runClient (sock, addr) originalSocket port killedChan clients chatrooms = do
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl LineBuffering
    handle (\(SomeException _) -> return ()) $ fix $ (\loop -> (loopClient hdl originalSocket port killedChan clients chatrooms []))
    hClose hdl
    clog "Client disconnected"


otherCommand :: Handle -> String -> IO ()
otherCommand hdl param = do
    clog $ "Received unknown query : " ++ param

killService :: Socket -> IO ()
killService originalSocket = do
    clog "Killing Service..."
    shutdown originalSocket ShutdownBoth
    close originalSocket

helo :: Handle -> String -> String -> IO ()
helo hdl text port = do
    clog $ "Responding to HELO command with params : " ++ text
    hostname <- getHostNameIfDockerOrNot
    sendResponse hdl $ "HELO " ++ text ++ "\nIP:" ++ hostname ++ "\nPort:" ++ port ++ "\nStudentID:17314158"

join :: Handle -> String -> String -> MVar Clients -> MVar ChatRooms -> IO (Bool, Int)
join hdl args port clients chatrooms = do
    clog $ "Receiving JOIN command with arguments : " ++ args
    let error = True
    let lines = splitOn "\n" args
    if not $ (length lines) == 4 then do
        sendError hdl 1 $ "Bad arguments for JOIN_CHATROOM."
        return (error, -1)
    else do
        let chatRoomName         = lines !! 0
        let clientIP             = lines !! 1
        let clientPort           = lines !! 2
        let clientNameLine       = lines !! 3
        let clientNameLineParsed = splitOn " " clientNameLine
        let clientNameHeader     = head clientNameLineParsed
        let clientName           = intercalate " " $ tail clientNameLineParsed
        if not ((clientIP == "CLIENT_IP: 0") && (clientPort == "PORT: 0") && (clientNameHeader == "CLIENT_NAME:")) then do
            sendError hdl 2 "Bad arguments for JOIN_CHATROOM."
            return (error, -1)
        else do
            (ChatRooms theChatrooms theChatroomsNames nbCR) <- takeMVar chatrooms
            wantedChatRoomID                        <- H.lookup theChatroomsNames chatRoomName
            (clientChanChat, roomRef, newNbCR)      <- case wantedChatRoomID of
                Just chatRoomRef -> do
                    wantedChatRoom <- H.lookup theChatrooms chatRoomRef
                    clientChanChat <- case wantedChatRoom of
                        Just (ChatRoom nbSubscribers chatChan) -> do
                            clientChanChat <- dupChan chatChan
                            H.insert theChatrooms chatRoomRef (ChatRoom (nbSubscribers+1) chatChan)
                            return clientChanChat
                        Nothing -> do
                            fakeChan <- newChan
                            return fakeChan
                    return (clientChanChat, chatRoomRef, nbCR)
                Nothing -> do
                    clientChanChat <- newChan
                    let newCRRef = nbCR + 1
                    H.insert theChatroomsNames chatRoomName newCRRef
                    H.insert theChatrooms newCRRef (ChatRoom 1 clientChanChat)
                    return (clientChanChat, newCRRef, newCRRef)
            putMVar chatrooms (ChatRooms theChatrooms theChatroomsNames newNbCR)
            (Clients lastClientId theClients clientsNames) <- takeMVar clients
            maybeClientId                        <- H.lookup clientsNames clientName
            (Client clientName channels joinId)  <- case maybeClientId of
                Just clientId -> do
                    maybeClient <- H.lookup theClients clientId
                    client      <- case maybeClient of
                        Just client -> return client
                        Nothing     -> do
                            htCTRefToChan <- H.new :: IO (HashTable Int (Chan String))
                            return (Client clientName htCTRefToChan (lastClientId+1))
                    return client
                Nothing       -> do
                    let joinId = lastClientId+1
                    H.insert clientsNames clientName joinId
                    htCTRefToChan <- H.new :: IO (HashTable Int (Chan String))
                    return (Client clientName htCTRefToChan joinId)
            H.insert channels roomRef clientChanChat
            H.insert theClients joinId (Client clientName channels joinId)
            putMVar clients (Clients joinId theClients clientsNames)
            writeChan clientChanChat $ "CHAT: " ++ (show roomRef) ++ "\nCLIENT_NAME: " ++ clientName ++ "\nMESSAGE: " ++ clientName ++ " has joined this chatroom.\n\n"
            serverIP <- getHostNameIfDockerOrNot
            let resp = "JOINED_CHATROOM: " ++ chatRoomName ++ "\nSERVER_IP: " ++ serverIP ++ "\nPORT: " ++ port ++ "\nROOM_REF: " ++ (show roomRef) ++ "\nJOIN_ID: " ++ (show joinId) ++ "\n"
            sendResponse hdl resp
            return (False, joinId)


leave :: Handle -> String -> MVar Clients -> IO (Bool, Int)
leave hdl args clients = do
    clog $ "Receiving LEAVE message with args : " ++ args
    let error = True
    let lines = splitOn "\n" args
    if not $ (length lines) == 3 then do
        sendError hdl 3 $ "Bad arguments for LEAVE_CHATROOM."
        return (error, -1)
    else do
        let chatRoomRefStr        = lines !! 0
        let joinIdLine            = lines !! 1
        let clientNameLine        = lines !! 2
        let clientNameLineParsed  = splitOn " " clientNameLine
        let clientNameHeader      = head clientNameLineParsed
        let clientNameGiven       = intercalate " " $ tail clientNameLineParsed
        let joinIdLineParsed      = splitOn " " joinIdLine
        let joinIdHeader          = head joinIdLineParsed
        let joinIdStr             = intercalate " " $ tail joinIdLineParsed
        let joinIdsCasted         = reads joinIdStr      :: [(Int, String)]
        let chatRoomRefsCasted    = reads chatRoomRefStr :: [(Int, String)]
        if not $ ((length joinIdsCasted) == 1 && (length chatRoomRefsCasted) == 1) then do
            sendError hdl 4 $ "Bad arguments for LEAVE_CHATROOM."
            return (error, -1)
        else do
            let (joinIdGivenByUser, restJ) = head joinIdsCasted
            let (chatRoomRef, restR)       = head chatRoomRefsCasted
            if not ((null restJ) && (null restR) && (clientNameHeader == "CLIENT_NAME:") && (joinIdHeader == "JOIN_ID:")) then do
                sendError hdl 5 "Bad arguments for LEAVE_CHATROOM."
                return (error, -1)
            else do
                (Clients lastClientId theClients clientsNames) <- takeMVar clients
                maybeClient                                    <- H.lookup theClients joinIdGivenByUser
                (Client clientName channels joinId, notFound)  <- case maybeClient of
                    Just client -> return (client, False)
                    Nothing     -> do
                        htCTRefToChan <- H.new :: IO (HashTable Int (Chan String))
                        return (Client "" htCTRefToChan (-1), True)
                if notFound then do
                    sendError hdl 12 "Unknown JOIN_ID for LEAVE_CHATROOM."
                    return (error, -1)
                else do
                    maybeChannel <- H.lookup channels chatRoomRef
                    let message = "CHAT: " ++ (show chatRoomRef) ++ "\nCLIENT_NAME: " ++ clientName ++ "\nMESSAGE: " ++ clientName ++ " has left this chatroom.\n\n"
                    case maybeChannel of
                        Just channel -> do
                            H.delete channels chatRoomRef
                            writeChan channel message
                        Nothing      -> return ()
                    H.insert theClients joinId (Client clientName channels joinId)
                    putMVar clients (Clients lastClientId theClients clientsNames)
                    let resp = "LEFT_CHATROOM: " ++ (show chatRoomRef) ++ "\nJOIN_ID: " ++ (show joinId) ++ "\n"
                    sendResponse hdl resp
                    sendResponse hdl message
                    return (False, joinId)

disconnect :: Handle -> String -> MVar Clients -> IO Bool
disconnect hdl args clients = do
    clog $ "Receiving DISCONNECT message with args : " ++ args
    let error = True
    let lines = splitOn "\n" args
    if not $ (length lines) == 3 then do
        sendError hdl 6 $ "Bad arguments for DISCONNECT."
        return error
    else do
        let disconnect            = lines !! 0
        let portLine              = lines !! 1
        let clientNameLine        = lines !! 2
        let clientNameLineParsed  = splitOn " " clientNameLine
        let clientNameHeader      = head clientNameLineParsed
        let clientNameGivenByUser = intercalate " " $ tail clientNameLineParsed
        if not ((disconnect == "0") && (portLine == "PORT: 0") && (clientNameHeader == "CLIENT_NAME:")) then do
            sendError hdl 7 "Bad arguments for DISCONNECT."
            return error
        else do
            (Clients lastClientId theClients clientsNames) <- takeMVar clients
            maybeClientId                                <- H.lookup clientsNames clientNameGivenByUser
            (Client clientName channels joinId, success) <- case maybeClientId of
                Just clientId -> do
                    maybeClient       <- H.lookup theClients clientId
                    (client, success) <- case maybeClient of
                        Just client -> return (client, True)
                        Nothing     -> do
                            htCTRefToChan <- H.new :: IO (HashTable Int (Chan String))
                            return (Client "" htCTRefToChan (-1), False)
                    return (client, success)
                Nothing       -> do
                    htCTRefToChan <- H.new :: IO (HashTable Int (Chan String))
                    return (Client "" htCTRefToChan (-1), False)
            if not success then do
                putMVar clients (Clients lastClientId theClients clientsNames)
                sendError hdl 14 "Client name does not exist."
                return error
            else do
                messages <- H.foldM (sendLeaveMessages clientNameGivenByUser) [] channels
                H.delete theClients joinId
                H.delete clientsNames clientName
                let messagesSortedAll = sortOn (\(m,chan,id) -> id) messages
                let messagesSorted = map (\(m,chan,id) -> m) $ messagesSortedAll
                let chans = map (\(m,chan,id) -> chan) $ messagesSortedAll
                clog $ show messagesSorted
                mapM_ (sendResponse hdl) messagesSorted
                sequence (zipWith ($) (map writeChan chans) messagesSorted)
                putMVar clients (Clients lastClientId theClients clientsNames)
                return True 


chat :: Handle -> String -> MVar Clients -> IO Bool
chat hdl args clients = do
    let error = True
    let request = splitOn "\nMESSAGE: " args
    if not $ (length request) >= 2 then do
        sendError hdl 8 $ "Incorrect arguments"
        return error
    else do
        let lines   = splitOn "\n" (request !! 0)
        let message = intercalate "\nMESSAGE: " $ tail request
        if not $ (length lines) == 3 then do
            sendError hdl 9 $ "Bad arguments for CHAT."
            return error
        else do
            let chatRoomRefStr        = lines !! 0
            let joinIdLine            = lines !! 1
            let clientNameLine        = lines !! 2
            let clientNameLineParsed  = splitOn " " clientNameLine
             let clientNameHeader      = head clientNameLineParsed
            let clientNameGiven       = intercalate " " $ tail clientNameLineParsed
            let joinIdLineParsed      = splitOn " " joinIdLine
            let joinIdHeader          = head joinIdLineParsed
            let joinIdStr             = intercalate " " $ tail joinIdLineParsed
            let joinIdsCasted         = reads joinIdStr      :: [(Int, String)]
            let chatRoomRefsCasted    = reads chatRoomRefStr :: [(Int, String)]
            if not $ ((length joinIdsCasted) == 1 && (length chatRoomRefsCasted) == 1) then do
                sendError hdl 10 $ "Bad arguments for CHAT."
                return error
            else do
                let (joinIdGivenByUser, restJ) = head joinIdsCasted
                let (chatRoomRef, restR)       = head chatRoomRefsCasted
                if not ((null restJ) && (null restR) && (clientNameHeader == "CLIENT_NAME:") && (joinIdHeader == "JOIN_ID:")) then do
                    sendError hdl 11 "Incorrect arguments"
                    return error
                else do
                    (Clients lastClientId theClients clientsNames) <- takeMVar clients
                    maybeClient                                    <- H.lookup theClients joinIdGivenByUser
                    (Client clientName channels joinId, notFound)  <- case maybeClient of
                        Just client -> return (client, False)
                        Nothing     -> do
                            htCTRefToChan <- H.new :: IO (HashTable Int (Chan String))
                            return (Client "" htCTRefToChan (-1), True)
                    if notFound then do
                        putMVar clients (Clients lastClientId theClients clientsNames)
                        sendError hdl 13 "Unknown JOIN_ID for CHAT."
                        return error
                    else do
                        maybeChannel <- H.lookup channels chatRoomRef
                        let resp = "CHAT: " ++ (show chatRoomRef) ++ "\nCLIENT_NAME: " ++ clientNameGiven ++ "\nMESSAGE: " ++ message ++ "\n"
                        clog $ "Chat sending : " ++ resp
                        error <- case maybeChannel of
                            Just channel -> do
                                writeChan channel resp
                                return False
                            Nothing      -> return True
                        putMVar clients (Clients lastClientId theClients clientsNames)
                        return error
