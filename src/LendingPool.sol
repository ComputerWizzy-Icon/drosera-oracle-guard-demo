// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IOracle {
    function getLatestPrice() external view returns (uint256);
}

contract LendingPool is Pausable, Ownable {
    uint256 public constant COLLATERAL_FACTOR_BPS = 7500;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IOracle public immutable ORACLE;
    address public responder;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    event ResponderUpdated(address indexed responder);
    event CollateralDeposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 price);
    event LiquidityFunded(address indexed sender, uint256 amount);
    event EmergencyPaused(address indexed responder);

    constructor(address owner_, address _oracle) Ownable(owner_) {
        require(owner_ != address(0), "Zero owner");
        require(_oracle != address(0), "Zero oracle");
        ORACLE = IOracle(_oracle);
    }

    modifier onlyResponder() {
        _onlyResponder();
        _;
    }

    function _onlyResponder() internal view {
        require(msg.sender == responder, "Not responder");
    }

    receive() external payable {
        emit LiquidityFunded(msg.sender, msg.value);
    }

    function setResponder(address _responder) external onlyOwner {
        require(_responder != address(0), "Zero responder");
        responder = _responder;
        emit ResponderUpdated(_responder);
    }

    function fundLiquidity() external payable onlyOwner {
        require(msg.value > 0, "Zero amount");
        emit LiquidityFunded(msg.sender, msg.value);
    }

    function depositCollateral() external payable whenNotPaused {
        require(msg.value > 0, "Zero deposit");
        collateral[msg.sender] += msg.value;
        emit CollateralDeposited(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external whenNotPaused {
        require(amount > 0, "Zero amount");
        require(amount <= address(this).balance, "Insufficient liquidity");

        uint256 price = ORACLE.getLatestPrice();
        require(price > 0, "Invalid price");

        uint256 maxBorrow = (collateral[msg.sender] *
            price *
            COLLATERAL_FACTOR_BPS) / (1e18 * BPS_DENOMINATOR);

        require(debt[msg.sender] + amount <= maxBorrow, "Exceeds borrow power");

        debt[msg.sender] += amount;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Transfer failed");
        emit Borrowed(msg.sender, amount, price);
    }

    function emergencyPause() external onlyResponder {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    function getTvl() external view returns (uint256) {
        return address(this).balance;
    }
}
