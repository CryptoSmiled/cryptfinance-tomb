// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./../dependencies/interfaces/IERC20.sol";
import "./IPool.sol";

contract MockContractUser {

    function tokenApprove(IERC20 _token, address _spender, uint256 _amount) public {
        _token.approve(_spender, _amount);
    }

    function poolDeposit(IPool _pool, uint256 _pid, uint256 _amount) public {
        _pool.deposit(_pid, _amount);
    }

    function poolWithdraw(IPool _pool, uint256 _pid, uint256 _amount) public {
        _pool.withdraw(_pid, _amount);
    }

}