// SPDX-License-Identifier: GPL-3.0

import "@openzeppelin/contracts/access/Ownable.sol";

pragma solidity ^0.8.7;


/** 
 * @title Tier System
 * @dev Defined list of contributors who can participate in UPDAO projects
 */
contract TierSystemManual is Ownable {
   
    mapping(address => mapping(address => uint) ) public allocations;

     /*
    Setup Allocaitons by admin
    */
    function setupAllocations(address tokensale, address[] calldata users, uint[] calldata amounts) public onlyOwner {
        
        require(users.length == amounts.length, "MATCH");

        for (uint i = 0; i < users.length; i++) {
            allocations[tokensale][users[i]] = amounts[i];
        }
    }

    /*
    Get allowed amount to contribute (used by tokensale contract)
    */
    function getAllocation(address tokensale, address _contributor) public view returns (uint) {
        return allocations[tokensale][_contributor];
    }
    
}