// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @dev A minimal Comet interface for the sake of testing integration
interface ICometMinimal {
    function supply(address asset, uint256 amount) external;
    function supplyTo(address dst, address asset, uint256 amount) external;
    function supplyFrom(address from, address dst, address asset, uint256 amount) external;

    function transfer(address dst, uint256 amount) external returns (bool);
    function transferFrom(address src, address dst, uint256 amount) external returns (bool);

    function transferAsset(address dst, address asset, uint256 amount) external;
    function transferAssetFrom(address src, address dst, address asset, uint256 amount) external;

    function withdraw(address asset, uint256 amount) external;
    function withdrawTo(address to, address asset, uint256 amount) external;
    function withdrawFrom(address src, address to, address asset, uint256 amount) external;
}
