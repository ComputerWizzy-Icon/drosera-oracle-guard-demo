// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IOracle {
    function getLatestPrice() external view returns (uint256);
}

contract LendingPool is Pausable, Ownable {
    IOracle public immutable oracle;
    address public responder;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    event ResponderUpdated(address indexed responder);
    event Borrowed(address indexed user, uint256 amount, uint256 price);
    event CollateralDeposited(address indexed user, uint256 amount);
    event EmergencyPaused(address indexed responder);

    constructor(address _oracle) Ownable(msg.sender) {
        oracle = IOracle(_oracle);
    }

    modifier onlyResponder() {
        require(msg.sender == responder, "Not responder");
        _;
    }

    function setResponder(address _responder) external onlyOwner {
        require(_responder != address(0), "Zero address");
        responder = _responder;
        emit ResponderUpdated(_responder);
    }

    function depositCollateral() external payable whenNotPaused {
        require(msg.value > 0, "Zero deposit");
        collateral[msg.sender] += msg.value;

        emit CollateralDeposited(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external whenNotPaused {
        uint256 price = oracle.getLatestPrice();

        uint256 borrowPower = (collateral[msg.sender] * price) / 1e18;

        require(
            debt[msg.sender] + amount <= borrowPower,
            "Exceeds borrow power"
        );

        require(amount <= address(this).balance, "Insufficient liquidity");

        debt[msg.sender] += amount;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Transfer failed");

        emit Borrowed(msg.sender, amount, price);
    }

    function emergencyPause() external onlyResponder {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function getTVL() external view returns (uint256) {
        return address(this).balance;
    }
}
