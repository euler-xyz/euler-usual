// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {EulerRouter} from "epo/EulerRouter.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {EulerKinkIRMFactory} from "evk-periphery/IRMFactory/EulerKinkIRMFactory.sol";
import {HookTargetAccessControl} from "evk-periphery/HookTarget/HookTargetAccessControl.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IEulerRouterFactory} from "evk-periphery/EulerRouterFactory/interfaces/IEulerRouterFactory.sol";
import "evk/EVault/shared/Constants.sol";

contract DeploymentScript is Script {
    // addresses taken from https://github.com/euler-xyz/euler-interfaces/tree/master/addresses/1
    address internal constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    IEulerRouterFactory internal constant eulerRouterFactory =
        IEulerRouterFactory(0x70B3f6F61b7Bf237DF04589DdAA842121072326A);
    EulerKinkIRMFactory internal constant irmFactory = EulerKinkIRMFactory(0xcAe0A39B45Ee9C3213f64392FA6DF30CE034C9F9);
    GenericFactory internal constant eVaultFactory = GenericFactory(0x29a56a1b8214D9Cf7c5561811750D5cBDb45CC8e);

    // asset addresses
    address internal constant USD = address(840);
    address internal constant USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
    address internal constant PT_USD0PP = 0x136389D329968bD82efe05F0911Eeb20eE74A138;

    // predeployed oracle adapters
    address internal constant USD0USD = 0x83e0698654dF4bC9F888c635ebE1382F0E4F7a61;
    address internal constant PT_USD0PPUSD = 0xd988620a4dCFaFa5d10A69b7bD1A296BE26DdEe9;

    // Usual addresses
    address internal constant GOVERNOR = 0x81ad394C0Fa87e99Ca46E1aca093BEe020f203f4; // USUAL Yield Treasury, visible here: https://tech.usual.money/smart-contracts/contract-deployments

    // vault parameters
    uint16 internal constant LIQUIDATION_COOL_OFF_TIME = 1;
    uint16 internal constant BORROW_LTV = 0.80e4;
    uint16 internal constant LIQUIDATION_LTV = 1e4 - 1;
    // 7% APY: floor(((7 / 100 + 1)**(1/(86400*365.2425)) - 1) * 1e27)
    uint256 internal constant BASE_INTEREST_RATE_7_PERCENT = 2144017221509398594;

    function run() public virtual {
        vm.startBroadcast();

        // deploy and configure the oracle router
        EulerRouter oracleRouter = EulerRouter(eulerRouterFactory.deploy(vm.getWallets()[0]));
        oracleRouter.govSetConfig(USD0, USD, USD0USD);
        oracleRouter.govSetConfig(PT_USD0PP, USD, PT_USD0PPUSD);

        // deploy and configure the PT_USD0++ vault
        IEVault ePT_USD0PP =
            IEVault(eVaultFactory.createProxy(address(0), true, abi.encodePacked(PT_USD0PP, oracleRouter, USD)));
        oracleRouter.govSetResolvedVault(address(ePT_USD0PP), true);
        ePT_USD0PP.setHookConfig(address(0), 0);

        // deploy and configure the USD0 vault
        IEVault eUSD0 = IEVault(eVaultFactory.createProxy(address(0), true, abi.encodePacked(USD0, oracleRouter, USD)));
        oracleRouter.govSetResolvedVault(address(eUSD0), true);
        eUSD0.setLiquidationCoolOffTime(LIQUIDATION_COOL_OFF_TIME);
        eUSD0.setInterestRateModel(irmFactory.deploy(BASE_INTEREST_RATE_7_PERCENT, 0, 0, type(uint32).max));
        eUSD0.setHookConfig(
            address(new HookTargetAccessControl(EVC, GOVERNOR, address(eVaultFactory))),
            OP_DEPOSIT | OP_MINT | OP_SKIM | OP_LIQUIDATE | OP_FLASHLOAN
        );
        eUSD0.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT);
        eUSD0.setLTV(address(ePT_USD0PP), BORROW_LTV, LIQUIDATION_LTV, 0);

        // transfer the governance
        oracleRouter.transferGovernance(GOVERNOR);
        ePT_USD0PP.setGovernorAdmin(GOVERNOR);
        eUSD0.setGovernorAdmin(GOVERNOR);

        vm.stopBroadcast();
    }
}
