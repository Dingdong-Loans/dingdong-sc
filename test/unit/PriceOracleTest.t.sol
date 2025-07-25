// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/core/PriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TellorPlayground} from "@tellor/contracts/TellorPlayground.sol";

contract PriceOracleTest is Test {
    string constant USD = "usd";
    string constant BTC = "wbtc";
    string constant ETH = "weth";

    string constant queryType = "SpotPrice";

    bytes constant queryDataBTC = abi.encode(queryType, abi.encode(BTC, USD));
    bytes constant queryDataETH = abi.encode(queryType, abi.encode(ETH, USD));
    bytes32 constant queryIdBTC = keccak256(queryDataBTC);
    bytes32 constant queryIdETH = keccak256(queryDataETH);

    PriceOracle priceOracle;
    TellorPlayground tellorOracle;

    /// @dev mock price with 8 decimals
    uint256 priceBTC = 100000e8;
    uint256 priceETH = 2500e8;

    MockERC20 tokenBTC;
    MockERC20 tokenETH;

    address admin = makeAddr("ADMIN");
    address user = makeAddr("USER");

    function setUp() public {
        console2.logBytes32(queryIdBTC);
        tokenBTC = new MockERC20("Bitcoin", "BTC", 18);
        tokenETH = new MockERC20("Ether", "ETH", 18);

        vm.startPrank(admin);
        tellorOracle = new TellorPlayground();
        priceOracle = new PriceOracle(admin, payable(address(tellorOracle)));

        // simulate regularly updated prices
        uint256 loopCount = 12;
        uint256 interval = 10 minutes;
        uint256 startTime = block.timestamp;
        uint256 blockNum = block.number;

        for (uint256 i = 0; i < loopCount; i++) {
            vm.warp(startTime + i * interval);
            vm.roll(blockNum + i); // force a new block

            tellorOracle.submitValue(queryIdBTC, abi.encode(priceBTC), 0, queryDataBTC);
            tellorOracle.submitValue(queryIdETH, abi.encode(priceETH), 0, queryDataETH);
        }
        vm.stopPrank();
    }

    // ========== setPriceFeed Test ==========
    function test_setPriceFeed() public {
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true);
        emit PriceOracle.PriceFeedSet(address(tokenBTC), BTC, USD);
        priceOracle.setPriceFeed(address(tokenBTC), BTC, USD);
        vm.stopPrank();

        (string memory base, string memory quote) = priceOracle.s_priceFeeds(address(tokenBTC));
        assertEq(base, BTC);
        assertEq(quote, USD);
    }

    function test_revert_setPriceFeed_UnauthorizedSender() public {
        vm.startPrank(user);
        vm.expectRevert();
        priceOracle.setPriceFeed(address(tokenBTC), BTC, USD);
        vm.stopPrank();
    }

    // ========== removePriceFeed Test ==========
    function test_removePriceFeed() public {
        vm.startPrank(admin);
        // set the price feed first
        priceOracle.setPriceFeed(address(tokenBTC), BTC, USD);

        // remove price feed
        vm.expectEmit(true, true, true, true);
        emit PriceOracle.PriceFeedRemoved(address(tokenBTC));
        priceOracle.removePriceFeed(address(tokenBTC));

        (string memory base, string memory quote) = priceOracle.s_priceFeeds(address(tokenBTC));
        assertEq(base, "");
        assertEq(quote, "");
        vm.stopPrank();
    }

    // ========== getValue Test ==========
    function test_getValue() public {
        // set the price feed
        vm.startPrank(admin);
        priceOracle.setPriceFeed(address(tokenBTC), BTC, USD);
        vm.stopPrank();

        // ensure dispute buffer passes
        vm.warp(block.timestamp + 1 hours);

        assertEq(priceOracle.getValue(address(tokenBTC), 1 * (10 ** tokenBTC.decimals())), priceBTC);
    }

    function test_revert_getValue_feedDoesNotExist() public {
        vm.expectRevert(PriceOracle.PriceOracle__FeedDoesNotExist.selector);
        priceOracle.getValue(address(tokenBTC), 1);
    }

    function test_revert_getValue_invalidPrice() public {
        // TWAP is implemented, so need to refactor this test
        vm.skip(true);

        // set the price feed
        vm.startPrank(admin);
        priceOracle.setPriceFeed(address(tokenBTC), BTC, USD);
        vm.stopPrank();

        // make the price invalid
        tellorOracle.submitValue(queryIdBTC, abi.encode(0), 0, queryDataBTC);

        // ensure dispute buffer passes
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(PriceOracle.PriceOracle__InvalidPrice.selector);
        priceOracle.getValue(address(tokenBTC), 1);
    }
}
