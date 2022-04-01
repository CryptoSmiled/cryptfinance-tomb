// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./dependencies/Ownable.sol";
import "./dependencies/lib/SafeERC20.sol";
import "./dependencies/lib/SafeMath.sol";

contract Distributor is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address[] public recipients;
    uint256[] public weightings;
    uint256 public totalWeights;

    constructor(address[] memory _recipients, uint256[] memory _weightings) public {
        recipients = _recipients;
        weightings = _weightings;

        totalWeights = 0;
        for (uint256 i = 0; i < _weightings.length; i++) {
            totalWeights = totalWeights.add(_weightings[i]);
        }
    }

    function setRecipients(address[] calldata _recipients) public onlyOwner {
        recipients = _recipients;
    }

    function setWeightings(uint256[] calldata _weightings) public onlyOwner {
        weightings = _weightings;
        totalWeights = 0;
        for (uint256 i = 0; i < _weightings.length; i++) {
            totalWeights = totalWeights.add(_weightings[i]);
        }
    }

    function tokenBalance(IERC20 _token) public view returns (uint256) {
        return _token.balanceOf(address(this));
    }

    function distribute_rewards(IERC20 _token) public {
        require(recipients.length == weightings.length, "Error: Recipients and Weights are not the same length.");
        uint256 totalBalance = tokenBalance(_token);
        uint256 remBalance = totalBalance;
        uint256 amount;

        uint256 length = recipients.length;
        for (uint256 i = 0; i < length; i++) {

            amount = totalBalance.mul(weightings[i]).div(totalWeights);

            if (amount > remBalance) { amount = remBalance; }
            remBalance = remBalance.sub(amount);

            _token.safeTransfer(recipients[i], amount);

        }
    }
}
