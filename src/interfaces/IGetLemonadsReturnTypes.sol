// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IGetLemonadsReturnTypes {
    struct GetLemonadsReturnType {
        address functionsRouter;
        bytes32 donId;
        uint64 functionsSubId;
        string clickAggregatorSource;
        string notificationSource;
        bytes secretReference;
    }
}
