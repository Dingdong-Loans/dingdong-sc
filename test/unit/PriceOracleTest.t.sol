// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../../src/core/PriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TellorPlayground} from "@tellor/contracts/TellorPlayground.sol";
import {TellorUser} from "../../src/tellor/TellorUser.sol";

contract PriceOracleTest is Test {
    // event redeclaration
    event PriceFeedSet(address indexed token, address feed);

    string constant USD = "usd";
    string constant BTC = "btc";
    string constant ETH = "eth";

    string constant queryType = "SpotPrice";

    bytes constant queryDataBTC = abi.encode(queryType, abi.encode(BTC, USD));
    bytes constant queryDataETH = abi.encode(queryType, abi.encode(ETH, USD));
    bytes32 constant queryIdBTC = keccak256(queryDataBTC);
    bytes32 constant queryIdETH = keccak256(queryDataETH);

    PriceOracle priceOracle;
    TellorPlayground tellorOracle;
    TellorUser pricefeedBTC;
    TellorUser pricefeedETH;

    /// @dev mock price with 8 decimals
    uint256 priceBTC = 100000e8;
    uint256 priceETH = 2500e8;

    MockERC20 tokenBTC;
    MockERC20 tokenETH;

    address admin = makeAddr("ADMIN");
    address user = makeAddr("USER");

    function setUp() public {
        tokenBTC = new MockERC20("Bitcoin", "BTC", 18);
        tokenETH = new MockERC20("Ether", "ETH", 18);

        vm.startPrank(admin);
        priceOracle = new PriceOracle(admin);
        tellorOracle = new TellorPlayground();

        pricefeedBTC = new TellorUser(payable(address(tellorOracle)), BTC, USD);
        pricefeedETH = new TellorUser(payable(address(tellorOracle)), ETH, USD);

        tellorOracle.submitValue(queryIdBTC, abi.encode(priceBTC), 0, queryDataBTC);
        tellorOracle.submitValue(queryIdETH, abi.encode(priceETH), 0, queryDataETH);
        vm.stopPrank();
    }

    // ========== setPriceFeed Test ==========
    function test_setPriceFeed() public {
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true);
        emit PriceFeedSet(address(tokenBTC), address(pricefeedBTC));
        priceOracle.setPriceFeed(address(tokenBTC), address(pricefeedBTC));
        vm.stopPrank();

        address priceFeedStored = priceOracle.getPriceFeed(address(tokenBTC));
        assertEq(priceFeedStored, address(pricefeedBTC));
    }

    function test_revert_setPriceFeed_UnauthorizedSender() public {
        vm.startPrank(user);
        vm.expectRevert();
        priceOracle.setPriceFeed(address(tokenBTC), address(pricefeedBTC));
        vm.stopPrank();
    }

    // ========== getValue Test ==========
    function test_getValue() public {
        // set the price feed
        vm.startPrank(admin);
        priceOracle.setPriceFeed(address(tokenBTC), address(pricefeedBTC));
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
        // set the price feed
        vm.startPrank(admin);
        priceOracle.setPriceFeed(address(tokenBTC), address(pricefeedBTC));
        vm.stopPrank();

        // make the price invalid
        tellorOracle.submitValue(queryIdBTC, abi.encode(0), 0, queryDataBTC);

        // ensure dispute buffer passes
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(PriceOracle.PriceOracle__InvalidPrice.selector);
        priceOracle.getValue(address(tokenBTC), 1);
    }
}
