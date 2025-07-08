// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/core/InterestRateModel.sol";
import {LendingCore} from "../../src/core/LendingCoreV1.sol";

contract InterestRateModelTest is Test {
    InterestRateModel interestRateModel;
    LendingCore lending;

    address public admin = makeAddr("ADMIN");
    address public pauser = makeAddr("PAUSER");
    address public upgrader = makeAddr("UPGRADER");
    address public parameterManager = makeAddr("PARAMETER_MANAGER");
    address public liquidityProvider = makeAddr("LIQUIDITY_PROVIDER");
    address public tokenManager = makeAddr("TOKEN_MANAGER");
    address public liquidator = makeAddr("LIQUIDATOR");

    address public tokenHandler = makeAddr("TOKEN_HANDLER");

    function setUp() public {}
}
