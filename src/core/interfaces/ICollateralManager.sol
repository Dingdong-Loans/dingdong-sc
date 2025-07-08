// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ICollateralManager
/// @notice Interface for the CollateralManager contract
interface ICollateralManager {
    /// @notice Deposits collateral for a user
    /// @param _user Address of the user
    /// @param _token Address of the token to deposit
    /// @param _amount Amount of the token to deposit
    function deposit(address _user, address _token, uint256 _amount) external;

    /// @notice Withdraws collateral for a user
    /// @param _user Address of the user
    /// @param _token Address of the token to withdraw
    /// @param _amount Amount of the token to withdraw
    function withdraw(address _user, address _token, uint256 _amount) external;

    /// @notice Adds a new collateral token
    /// @param _token Address of the token to add
    function addCollateralToken(address _token) external;

    /// @notice Removes a collateral token
    /// @param _token Address of the token to remove
    function removeCollateralToken(address _token) external;

    /// @notice Gets the amount of collateral a user has deposited
    /// @param _user Address of the user
    /// @param _token Address of the token
    /// @return amount of the specified token deposited by the user
    function getDepositedCollateral(address _user, address _token) external view returns (uint256);
}
