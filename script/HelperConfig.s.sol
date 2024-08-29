// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {LinkToken} from "../test/mocks/LinkToken.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";
import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        bytes32 donId;
        address functionsRouter;
        address nativeUsdPriceFeed;
        uint64 functionsSubId;
        address ccipRouterAddress;
        address linkTokenAddress;
        address usdcAddress;
        address usdcPriceFeed;
    }

    uint256 public constant DEFAULT_ANVIL_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8;
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 80002) {
            activeNetworkConfig = getPolygonAmoyConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getPolygonAmoyConfig() public pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                donId: bytes32("fun-polygon-amoy-1"),
                functionsRouter: 0xC22a79eBA640940ABB6dF0f7982cc119578E11De,
                nativeUsdPriceFeed: 0x001382149eBa3441043c1c66972b4772963f5D43,
                usdcPriceFeed: 0x1b8739bB4CdF0089d07097A9Ae5Bd274b29C6F16,
                functionsSubId: 341,
                ccipRouterAddress: 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2,
                linkTokenAddress: 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904,
                usdcAddress: 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
            });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.functionsRouter != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        LinkToken link = new LinkToken();
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(
            DECIMALS,
            INITIAL_PRICE
        );
        vm.stopBroadcast();

        return
            NetworkConfig({
                donId: bytes32("fun-ethereum-sepolia-1"),
                functionsRouter: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
                nativeUsdPriceFeed: address(mockPriceFeed),
                usdcPriceFeed: address(mockPriceFeed),
                functionsSubId: 0,
                ccipRouterAddress: 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2,
                linkTokenAddress: address(link),
                usdcAddress: 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
            });
    }
}
