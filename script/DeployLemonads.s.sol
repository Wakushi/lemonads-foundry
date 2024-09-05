// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Lemonads} from "../src/Lemonads.sol";
import {IGetLemonadsReturnTypes} from "../src/interfaces/IGetLemonadsReturnTypes.sol";
import {IFunctionsSubscriptions} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsSubscriptions.sol";
import "forge-std/console.sol";

contract DeployLemonads is Script {
    string constant CLICK_AGGREGATOR_SOURCE =
        "./functions/sources/click-aggregator-source.js";
    string constant NOTIFICATION_SOURCE =
        "./functions/sources/notification-source.js";

    function run() external {
        IGetLemonadsReturnTypes.GetLemonadsReturnType
            memory lemonadsReturnType = getLemonadsRequirements();

        vm.startBroadcast();
        address newLemonads = deployLemonads(
            lemonadsReturnType.functionsRouter,
            lemonadsReturnType.donId,
            lemonadsReturnType.functionsSubId,
            lemonadsReturnType.clickAggregatorSource,
            lemonadsReturnType.notificationSource,
            lemonadsReturnType.secretReference,
            lemonadsReturnType.nativeToUsdpriceFeed
        );
        IFunctionsSubscriptions(lemonadsReturnType.functionsRouter).addConsumer(
                lemonadsReturnType.functionsSubId,
                newLemonads
            );
        vm.stopBroadcast();
    }

    function getLemonadsRequirements()
        public
        returns (IGetLemonadsReturnTypes.GetLemonadsReturnType memory)
    {
        HelperConfig helperConfig = new HelperConfig();
        (
            bytes32 donId,
            address functionsRouter,
            address nativeToUsdpriceFeed,
            uint64 functionsSubId,
            ,
            ,
            ,
            ,
            bytes memory secretReference
        ) = helperConfig.activeNetworkConfig();

        string memory clickAggregatorSource = vm.readFile(
            CLICK_AGGREGATOR_SOURCE
        );

        string memory notificationSource = vm.readFile(NOTIFICATION_SOURCE);

        if (
            functionsRouter == address(0) ||
            donId == bytes32(0) ||
            bytes(clickAggregatorSource).length == 0
        ) {
            revert("something is wrong");
        }

        return
            IGetLemonadsReturnTypes.GetLemonadsReturnType(
                functionsRouter,
                donId,
                functionsSubId,
                clickAggregatorSource,
                notificationSource,
                secretReference,
                nativeToUsdpriceFeed
            );
    }

    function deployLemonads(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        string memory _clickAggregatorSource,
        string memory _notificationSource,
        bytes memory _secretReference,
        address _nativeToUsdpriceFeed
    ) public returns (address) {
        Lemonads newLemonads = new Lemonads(
            _functionsRouter,
            _donId,
            _functionsSubId,
            _clickAggregatorSource,
            _notificationSource,
            _secretReference,
            _nativeToUsdpriceFeed
        );
        return address(newLemonads);
    }
}
