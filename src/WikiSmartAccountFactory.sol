// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/utils/Create2.sol";
import "./WikiSmartAccount.sol";
/**
 * @title WikiSmartAccountFactory — CREATE2 factory for smart accounts
 * Deploys deterministic account addresses before first use (counterfactual deployment).
 */
contract WikiSmartAccountFactory {
    event AccountCreated(address indexed account, address indexed owner, uint256 salt);
    
    function createAccount(address owner, address[] calldata guardians, uint256 threshold, uint256 salt) external returns (WikiSmartAccount account) {
        bytes32 s = keccak256(abi.encodePacked(owner, salt));
        address predicted = Create2.computeAddress(s, keccak256(abi.encodePacked(type(WikiSmartAccount).creationCode, abi.encode(owner, guardians, threshold))));
        if (predicted.code.length > 0) return WikiSmartAccount(payable(predicted));
        account = new WikiSmartAccount{salt: s}(owner, guardians, threshold);
        emit AccountCreated(address(account), owner, salt);
    }
    function getAddress(address owner, uint256 salt) external view returns (address) {
        bytes32 s = keccak256(abi.encodePacked(owner, salt));
        return Create2.computeAddress(s, keccak256(abi.encodePacked(type(WikiSmartAccount).creationCode, abi.encode(owner, new address[](0), uint256(1)))));
    }
}
