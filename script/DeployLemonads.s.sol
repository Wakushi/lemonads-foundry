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

    function run() external {
        IGetLemonadsReturnTypes.GetLemonadsReturnType
            memory lemonadsReturnType = getLemonadsRequirements();

        vm.startBroadcast();
        address newLemonads = deployLemonads(
            lemonadsReturnType.functionsRouter,
            lemonadsReturnType.donId,
            lemonadsReturnType.functionsSubId,
            lemonadsReturnType.clickAggregatorSource
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
            ,
            uint64 functionsSubId,
            ,
            ,
            ,

        ) = helperConfig.activeNetworkConfig();

        string memory clickAggregatorSource = vm.readFile(
            CLICK_AGGREGATOR_SOURCE
        );

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
                clickAggregatorSource
            );
    }

    function deployLemonads(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        string memory _clickAggregatorSource
    ) public returns (address) {
        Lemonads newLemonads = new Lemonads(
            _functionsRouter,
            _donId,
            _functionsSubId,
            _clickAggregatorSource
        );
        return address(newLemonads);
    }
}
