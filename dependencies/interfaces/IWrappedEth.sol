// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./IERC20.sol";

interface IWrappedEth is IERC20 {
    function deposit() external payable returns (uint256);

    function withdraw(uint256 amount) external returns (uint256);

}

