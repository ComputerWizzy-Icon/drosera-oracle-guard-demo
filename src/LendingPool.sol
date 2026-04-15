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

    uint256 public totalValueLocked;
    mapping(address => uint256) public collateral;

    event ResponderUpdated(address indexed responder);
    event Borrowed(address indexed user, uint256 amount, uint256 price);
    event CollateralDeposited(address indexed user, uint256 amount);
    event EmergencyPaused(address indexed responder);

    constructor(address _oracle) payable Ownable(msg.sender) {
        oracle = IOracle(_oracle);
        totalValueLocked = msg.value;
    }

    modifier onlyResponder() {
        require(msg.sender == responder, "Not Drosera Responder");
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
        totalValueLocked += msg.value;

        emit CollateralDeposited(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external whenNotPaused {
        uint256 price = oracle.getLatestPrice();

        // Vulnerable logic: Borrow power directly scales with manipulated price
        uint256 borrowPower = (collateral[msg.sender] * price) / 1000;

        require(borrowPower >= amount, "Inadequate collateral");
        require(amount <= totalValueLocked, "Insufficient pool liquidity");

        totalValueLocked -= amount;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "ETH transfer failed");

        emit Borrowed(msg.sender, amount, price);
    }

    function emergencyPause() external onlyResponder {
        _pause();
        emit EmergencyPaused(msg.sender);
    }
}
