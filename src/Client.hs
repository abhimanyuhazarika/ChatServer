module Client where

import ChatHelpers
import Network.Socket
import System.IO
import Control.Concurrent
import Data.List
import Data.List.Split
import Control.Concurrent.MVar
import qualified Data.HashTable.IO as H

-- Kill server and all clients
killService :: Socket -> IO ()
killService originalSocket = do
    clog "Killing Service..."
    shutdown originalSocket ShutdownBoth
    close originalSocket

-- Basic "Helo" response
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
        sendError hdl 1 $ "Insufficient arguments for JOIN_CHATROOM."
        return (error, -1)
    else do
        let chatRoomName= lines !! 0
        let clientIP= lines !! 1
        let clientPort = lines !! 2
        let clientNameLine = lines !! 3
        let clientNameLineParsed = splitOn " " clientNameLine
        let clientNameHeader = head clientNameLineParsed
        let clientName = intercalate " " $ tail clientNameLineParsed
        if not ((clientIP == "CLIENT_IP: 0") && (clientPort == "PORT: 0") && (clientNameHeader == "CLIENT_NAME:")) then do
            sendError hdl 2 "Insufficientarguments for JOIN_CHATROOM."
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

