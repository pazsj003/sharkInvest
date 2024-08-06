// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/DecimalMath.sol";
import "../intf/ID3Vault.sol";
import "../../intf/ID3Oracle.sol";
import "./D3Storage.sol";

/// @notice pool funding model, manage pool borrow/repay and maker deposi/withdraw
contract D3Funding is D3Storage {
    using SafeERC20 for IERC20;

    /// @notice borrow tokens from vault
    function borrow(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant poolOngoing {
        // call vault's poolBorrow function
        ID3Vault(state._D3_VAULT_).poolBorrow(token, amount); // 只是transfer 到 本合约
        /* approve max, ensure vault could force liquidate 为什么在 poolBorrow 之后检查和授权？
        借款操作的独立性：
        借款操作需要首先完成，以确保借出的代币确实到账。
        授权操作是为了确保将来 D3Vault 可以处理这些代币（例如，进行强制清算）。*/
        uint256 allowance = IERC20(token).allowance(
            address(this),
            state._D3_VAULT_
        );
        if (allowance < type(uint256).max) {
            IERC20(token).forceApprove(state._D3_VAULT_, type(uint256).max);
        } // 强制清算 授权max  可能会有问题，无限授权的风险：将 allowance 设置为最大值 type(uint256).max 可能带来安全隐患，因为 D3Vault 可以无限制地提取 token。
        //替代方案：可以考虑限制授权数量、定期授权或分批授权，以提高安全性。

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
        require(checkBorrowSafe(), Errors.NOT_BORROW_SAFE);
    }

    /// @notice repay vault with certain amount of borrowed assets
    function repay(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant poolOngoing {
        // call vault's poolRepay
        ID3Vault(state._D3_VAULT_).poolRepay(token, amount); //D3VaultFunding.poolRepay

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
    }

    /// @notice repay vault all debt of this token
    function repayAll(
        address token
    ) external onlyOwner nonReentrant poolOngoing {
        ID3Vault(state._D3_VAULT_).poolRepayAll(token);

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
    }

    /// @notice used through liquidation
    function updateReserveByVault(address token) external onlyVault {
        uint256 allowance = IERC20(token).allowance(
            address(this),
            state._D3_VAULT_
        );
        if (allowance < type(uint256).max) {
            IERC20(token).forceApprove(state._D3_VAULT_, type(uint256).max);
        }
        _updateReserve(token);
    }

    /// @notice maker deposit, anyone could deposit but only maker could withdraw
    function makerDeposit(address token) external nonReentrant poolOngoing {
        require(
            ID3Oracle(state._ORACLE_).isFeasible(token),
            Errors.TOKEN_NOT_FEASIBLE
        );
        if (!state.hasDepositedToken[token]) {
            state.hasDepositedToken[token] = true;
            state.depositedTokenList.push(token);
        }
        // transfer in from proxies // 计算存入的代币数量
        uint256 tokenInAmount = IERC20(token).balanceOf(address(this)) -
            state.balances[token];
        _updateReserve(token);
        // if token in tokenlist, approve max, ensure vault could force liquidate
        uint256 allowance = IERC20(token).allowance(
            address(this),
            state._D3_VAULT_
        );
        if (_checkTokenInTokenlist(token) && allowance < type(uint256).max) {
            IERC20(token).forceApprove(state._D3_VAULT_, type(uint256).max);
        }
        require(checkSafe(), Errors.NOT_SAFE);

        emit MakerDeposit(token, tokenInAmount);
    }

    function makerWithdraw(
        address to,
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant poolOngoing {
        // owner 可以随意转移 给to 地址没有限制
        IERC20(token).safeTransfer(to, amount);

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
        require(checkBorrowSafe(), Errors.NOT_BORROW_SAFE);

        emit MakerWithdraw(to, token, amount);
    }

    // below IM: not safe!
    function checkSafe() public view returns (bool) {
        return ID3Vault(state._D3_VAULT_).checkSafe(address(this)); // D3VaultFunding.checkSafe()
    }

    // check when borrowing asset
    function checkBorrowSafe() public view returns (bool) {
        return ID3Vault(state._D3_VAULT_).checkBorrowSafe(address(this));
    }

    // blow MM: dangerous!
    function checkCanBeLiquidated() public view returns (bool) {
        return ID3Vault(state._D3_VAULT_).checkCanBeLiquidated(address(this));
    }

    function startLiquidation() external onlyVault {
        isInLiquidation = true;
    }

    function finishLiquidation() external onlyVault {
        isInLiquidation = false;
    }

    function _updateReserve(address token) internal {
        state.balances[token] = IERC20(token).balanceOf(address(this));
    }

    function _checkTokenInTokenlist(
        address token
    ) internal view returns (bool) {
        return ID3Vault(state._D3_VAULT_).tokens(token);
    }
}
