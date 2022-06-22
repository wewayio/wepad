// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";

/* 
    KYC registry smart contract is managed by WePad adminitratory

    Functionlity:
        * Administrator can add reviewed allowed address into the registry
        * Registry could be used in Tokensale to verify allowed address
        * Adminitrator could remove allowed address from the registry
        * Administrator could transfer ownership to another administrator or smart contact 
        * Registry Smart Contract should be deployed once and then used by other smart contracts
*/

/*

    Usage example 

    abstract contract IKYCRegistry {
        mapping(address => bool) public allowed;
    } 


    contract TokensaleContract {
    
        IKYCRegistry kycRegistry;

        constructor(IKYCRegistry _kycRegistery) {
            kycRegistry = _kycRegistery;

            require(kycRegistry.allowed(address(0x0)) == false, "should be always false");
        }

    }

*/

contract KYCRegistry is Ownable {

    /*
    Event can be used by the https://github.com/graphprotocol/graph-node or getPastLogs(fromBlock, toBlock)
    */
    event Added(address user, bool allowed);

    /*
    Registry itself
    */
    mapping(address => bool) public allowed;

    /*
    Aministrator function to add KYC allowance
    */
    function setAcceptStatus(address token, bool status) private   {
        require(token != address(0x0));
        allowed[token] = status;
        emit Added(token, status);
    }

    struct Allowance {
        address user;
        bool status;
    }

    /*
    Aministrator function to add multiple KYC allowances
    */
    function setAcceptStatuses(Allowance[] calldata allowances) public onlyOwner  {
        for (uint i =0; i < allowances.length; i++) {
            setAcceptStatus(allowances[i].user, allowances[i].status);
        }
    }

}