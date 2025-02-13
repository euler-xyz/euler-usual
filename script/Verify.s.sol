// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {EulerRouter} from "epo/EulerRouter.sol";
import {IRMLinearKink} from "evk/InterestRateModels/IRMLinearKink.sol";
import {EulerKinkIRMFactory} from "evk-periphery/IRMFactory/EulerKinkIRMFactory.sol";
import {IEVault, IERC4626, IVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {IEulerRouterFactory} from "evk-periphery/EulerRouterFactory/interfaces/IEulerRouterFactory.sol";
import {HookTargetAccessControl} from "evk-periphery/HookTarget/HookTargetAccessControl.sol";
import "evk/EVault/shared/Constants.sol";

import {DeploymentScript} from "./Deploy.s.sol";

contract VerifyVaultConfig is DeploymentScript {
    address internal constant EUSD0_VAULT = 0xd001f0a15D272542687b2677BA627f48A4333b5d;
    address internal constant EUSD0PP_VAULT = 0xF037eeEBA7729c39114B9711c75FbccCa4A343C8;
    address internal constant ORACLE = 0xa5A802ABa1F830F4eEAba6D1D5A13d65DaE8f640;
    address internal constant IRM = 0x18Cf69d44a4742D7EbB9D7cDEE55414f17B6bB69;
    address internal constant HOOK_TARGET = 0xB3d9fa3d6dE1deEc9A10aFee4b57f57637e0329f;
    address internal constant PROTOCOL_CONFIG = 0x4cD6BF1D183264c02Be7748Cb5cd3A47d013351b;
    uint32 internal constant HOOKED_OPS = OP_DEPOSIT | OP_MINT | OP_SKIM | OP_LIQUIDATE | OP_FLASHLOAN;

    // Set to address(0) after renouncing governance
    address internal constant TARGET_GOVERNOR = GOVERNOR;

    function run() public view override {
        verifyUSD0();
        verifyUSD0PP();
    }

    function verifyUSD0() internal view {
        // immutables
        require(eVaultFactory.isProxy(EUSD0_VAULT), "Not a factory proxy");
        require(eVaultFactory.getProxyConfig(EUSD0_VAULT).upgradeable, "Not upgradeable");
        require(IEVault(EUSD0_VAULT).asset() == USD0, "Wrong asset");
        require(IEVault(EUSD0_VAULT).unitOfAccount() == USD, "Wrong unit of accout");
        require(IEVault(EUSD0_VAULT).protocolConfigAddress() == PROTOCOL_CONFIG, "Wrong protocol config");

        // governance basics
        require(IEVault(EUSD0_VAULT).governorAdmin() == TARGET_GOVERNOR, "Wrong vault governor");
        require(IEVault(EUSD0_VAULT).feeReceiver() == address(0), "Wrong fee receiver");
        require(IEVault(EUSD0_VAULT).interestFee() == 0.03e4, "Wrong interest fee");

        // IRM
        require(IEVault(EUSD0_VAULT).interestRateModel() == IRM, "Wrong IRM");
        require(irmFactory.isValidDeployment(IRM), "Invalid IRM");
        require(IRMLinearKink(IRM).baseRate() == BASE_INTEREST_RATE_5_PERCENT, "Wrong IRM base rate");
        require(IRMLinearKink(IRM).slope1() == 0, "Wrong IRM slope1");
        require(IRMLinearKink(IRM).slope2() == 0, "Wrong IRM slope2");

        // oracle
        require(IEVault(EUSD0_VAULT).oracle() == ORACLE, "Wrong oracle");
        require(eulerRouterFactory.isValidDeployment(ORACLE), "Not valid oracle router");
        require(EulerRouter(ORACLE).governor() == TARGET_GOVERNOR, "Wrong oracle governor");
        require(EulerRouter(ORACLE).fallbackOracle() == address(0), "Wrong fallback oracle");
        require(EulerRouter(ORACLE).getConfiguredOracle(USD0, USD) == USD0USD, "Wrong USD0 to USD oracle adapter");
        require(EulerRouter(ORACLE).getConfiguredOracle(USD0PP, USD) == USD0PPUSD, "Wrong USD0++ to USD oracle adapter");
        require(EulerRouter(ORACLE).resolvedVaults(EUSD0PP_VAULT) == USD0PP, "Wrong USD0++ resolved vault");

        // hooks
        {
            (address hookTarget, uint32 hookedOps) = IEVault(EUSD0_VAULT).hookConfig();
            require(hookTarget == HOOK_TARGET, "Wrong hook target");
            require(hookedOps == HOOKED_OPS, "Wrong hooked ops");

            address[] memory depositors = HookTargetAccessControl(hookTarget).getRoleMembers(IERC4626.deposit.selector);
            require(depositors.length == 1, "Wrong allowed depositors count");
            require(depositors[0] == GOVERNOR, "Wrong depositor");

            address[] memory minters = HookTargetAccessControl(hookTarget).getRoleMembers(IERC4626.mint.selector);
            require(minters.length == 0, "Wrong allowed minters count");

            address[] memory skimmers = HookTargetAccessControl(hookTarget).getRoleMembers(IVault.skim.selector);
            require(skimmers.length == 0, "Wrong allowed skimmers count");

            address[] memory flashborrowers =
                HookTargetAccessControl(hookTarget).getRoleMembers(IBorrowing.flashLoan.selector);
            require(flashborrowers.length == 0, "Wrong allowed flashborrowers count");
        }

        // caps
        {
            (uint32 supplyCap, uint32 borrowCap) = IEVault(EUSD0_VAULT).caps();
            require(supplyCap == 0, "Wrong supply cap");
            require(borrowCap == 0, "Wrong borrow cap");
        }

        // config flags
        require(IEVault(EUSD0_VAULT).configFlags() == CFG_DONT_SOCIALIZE_DEBT, "Wrong config flags");

        // liquidations
        require(IEVault(EUSD0_VAULT).maxLiquidationDiscount() == 0, "Wrong liquidation discount");
        require(
            IEVault(EUSD0_VAULT).liquidationCoolOffTime() == LIQUIDATION_COOL_OFF_TIME,
            "Wrong liquidation cool off time"
        );

        // collaterals
        {
            address[] memory collaterals = IEVault(EUSD0_VAULT).LTVList();
            require(collaterals.length == 1, "Wrong collaterals count");

            (uint16 borrowLTV, uint16 liquidationLTV, uint16 initialLiquidationLTV,, uint32 rampDuration) =
                IEVault(EUSD0_VAULT).LTVFull(collaterals[0]);

            require(borrowLTV == BORROW_LTV, "Wrong borrow LTV");
            require(liquidationLTV == LIQUIDATION_LTV, "Wrong liquidation LTV");
            require(initialLiquidationLTV == 0, "Wrong initial liquidation LTV");
            require(rampDuration == 0, "Wrong LTV ramp duration");
        }
    }

    function verifyUSD0PP() internal view {
        // immutables
        require(eVaultFactory.isProxy(EUSD0PP_VAULT), "PP: Not a factory proxy");
        require(eVaultFactory.getProxyConfig(EUSD0PP_VAULT).upgradeable, "PP: Not upgradeable");
        require(IEVault(EUSD0PP_VAULT).asset() == USD0PP, "PP: Wrong asset");
        require(IEVault(EUSD0PP_VAULT).unitOfAccount() == USD, "PP: Wrong unit of accout");
        require(IEVault(EUSD0_VAULT).protocolConfigAddress() == PROTOCOL_CONFIG, "Wrong protocol config");

        // governance basics
        require(IEVault(EUSD0PP_VAULT).governorAdmin() == TARGET_GOVERNOR, "PP: Wrong vault governor");
        require(IEVault(EUSD0PP_VAULT).feeReceiver() == address(0), "PP: Wrong fee receiver");

        // IRM
        require(IEVault(EUSD0PP_VAULT).interestRateModel() == address(0), "PP: Wrong IRM");

        // oracle
        require(IEVault(EUSD0PP_VAULT).oracle() == ORACLE, "PP: Wrong oracle");

        // hooks
        {
            (address hookTarget, uint32 hookedOps) = IEVault(EUSD0PP_VAULT).hookConfig();
            require(hookTarget == address(0), "PP: Wrong hook target");
            require(hookedOps == 0, "PP: Wrong hooked ops");
        }

        // caps
        {
            (uint32 supplyCap, uint32 borrowCap) = IEVault(EUSD0PP_VAULT).caps();
            require(supplyCap == 0, "PP: Wrong supply cap");
            require(borrowCap == 0, "PP: Wrong borrow cap");
        }

        // config flags
        require(IEVault(EUSD0PP_VAULT).configFlags() == 0, "PP: Wrong config flags");

        // liquidations
        require(IEVault(EUSD0PP_VAULT).maxLiquidationDiscount() == 0, "PP: Wrong liquidation discount");
        require(IEVault(EUSD0PP_VAULT).liquidationCoolOffTime() == 0, "PP: Wrong liquidation cool off time");

        // collaterals
        {
            require(IEVault(EUSD0PP_VAULT).LTVList().length == 0, "PP: Wrong collaterals count");
        }
    }
}
