// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

// WETH
interface IWETH9 {
    function withdraw(uint256 wad) external;
}

// Aave
interface ILendingPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IFlashLoanSimpleReceiver {
    /**
     * @notice Executes an operation after receiving the flash-borrowed asset
     * @dev Ensure that the contract can return the debt + premium, e.g., has
     *      enough funds to repay and has approved the Pool to pull the total amount
     * @param asset The address of the flash-borrowed asset
     * @param amount The amount of the flash-borrowed asset
     * @param premium The fee of the flash-borrowed asset
     * @param initiator The address of the flashloan initiator
     * @param params The byte-encoded params passed when initiating the flashloan
     * @return True if the execution of the operation succeeds, false otherwise
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

abstract contract FlashLoanSimpleReceiverBase is IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    ILendingPool public immutable LENDING_POOL;

    constructor(address provider) {
        ADDRESSES_PROVIDER = IPoolAddressesProvider(provider);
        LENDING_POOL = ILendingPool(IPoolAddressesProvider(provider).getPool());
    }

    receive() external payable virtual {}
}

// Uniswap V2
interface IUniswapV2Router01 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// Uniswap V3
library TransferHelper {
    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SA"
        );
    }
}

interface ISwapRouter is IUniswapV3SwapCallback, IUniswapV2Router02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

contract newFilter {
    enum DEX_PATH {
        UNIV3_UNIV2,
        UNIV3_SUSHI,
        UNIV2_UNIV3,
        SUSHI_UNIV3,
        UNIV2_SUSHI,
        SUSHI_UNIV2
    }

    enum DEX_Selection {
        SUSHI,
        UNIV2,
        UNIV3
    }
}

// Contract
contract Flashloan is FlashLoanSimpleReceiverBase, newFilter {
    address payable owner;

    uint256 private quantity;
    address[] private tokens_addresses;

    uint8 private arb_swap_path;
    uint24 private fee;

    // SEPOLIA CONTRACT
    IUniswapV2Router02 public constant sushi_router_v2 =
        IUniswapV2Router02(0xEfF92A263d31888d860bD50809A8D171709b7b1c);
    IUniswapV2Router02 public constant uni_router_v2 =
        IUniswapV2Router02(0x1fb44dF2ECb24bF80b8e89c33B958b222a2d09C6);
    ISwapRouter public constant uni_router_v3 =
        ISwapRouter(0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E);
    IWETH9 public constant weth =
        IWETH9(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);

    constructor(
        address _addressProvider
    ) FlashLoanSimpleReceiverBase(_addressProvider) {
        owner = payable(msg.sender);
    }

    // Events
    event Received(address sender, uint256 value);
    event Withdraw(address to, uint256 value);
    event Minner_fee(uint256 value);
    event Withdraw_token(address to, uint256 value);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the Owner");
        _;
    }

    modifier checking_amount(address token, uint256 amount) {
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "The amount exceeds balance!"
        );
        _;
    }

    function new_owner(
        address payable _new_owner
    ) external onlyOwner returns (bool) {
        owner = _new_owner;
        return true;
    }

    receive() external payable override {}

    function withdraw(uint256 _amount) public onlyOwner returns (bool) {
        require(_amount <= address(this).balance, "Insufficient ETH amount!");
        owner.transfer(_amount);

        emit Withdraw(owner, _amount);
        return true;
    }

    function withdraw_weth(uint8 _percentage) public onlyOwner returns (bool) {
        require(
            IERC20(address(weth)).balanceOf(address(this)) > 0,
            "There is no WETH balance!"
        );
        require(
            (0 < _percentage) && (_percentage <= 100),
            "Invalid percentage!"
        );

        weth.withdraw(IERC20(address(weth)).balanceOf(address(this)));

        uint256 amount_to_withdraw = (_percentage * address(this).balance) /
            100;

        block.coinbase.transfer(amount_to_withdraw);
        emit Minner_fee(amount_to_withdraw);

        return withdraw(address(this).balance);
    }

    function withdraw_token(address _token) public onlyOwner returns (bool) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "There is no token balance!");
        bool check = IERC20(_token).transfer(owner, balance);

        emit Withdraw_token(owner, balance);
        return check;
    }

    function withdraw_filter(
        address _token,
        uint8 _percentage,
        uint8 _dex,
        uint24 _dexfee
    ) public onlyOwner returns (bool) {
        if (_token == address(weth)) {
            return withdraw_weth(_percentage);
        } else {
            // The lines below are not the best way to proceed, because of we've aumented the number of txs however the payment for the minner is only allowed with WETH
            require(_dex < 3, "Invalid dex option for withdraw ETH!");
            if (DEX_Selection.SUSHI == DEX_Selection(_dex)) {
                sushi(
                    _token,
                    address(weth),
                    IERC20(_token).balanceOf(address(this))
                );
                return withdraw_weth(_percentage);
            }
            if (DEX_Selection.UNIV2 == DEX_Selection(_dex)) {
                uni_v2(
                    _token,
                    address(weth),
                    IERC20(_token).balanceOf(address(this))
                );
                return withdraw_weth(_percentage);
            }
            if (DEX_Selection.UNIV3 == DEX_Selection(_dex)) {
                require(
                    (_dexfee == 500) || (_dexfee == 3000) || (_dexfee == 10000),
                    "Invalid fee for swapping in UniV3"
                );
                uni_v3(
                    _token,
                    address(weth),
                    IERC20(_token).balanceOf(address(this)),
                    _dexfee
                );
                return withdraw_weth(_percentage);
            }
            return false;
        }
    }

    function get_path(
        address _tokenIn,
        address _tokenOut
    ) internal pure returns (address[] memory) {
        address[] memory path;
        path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        return path;
    }

    function get_amounts_out(
        uint256 _amountIn,
        address[] memory _path,
        IUniswapV2Router02 _router
    ) public view returns (uint256) {
        uint256[] memory amountsOut = _router.getAmountsOut(_amountIn, _path);
        uint256 amountOutMin = amountsOut[amountsOut.length - 1];
        return amountOutMin;
    }

    // Functions for swapping on 3 main dexes

    function sushi(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) public checking_amount(_tokenIn, _amountIn) {
        IERC20(_tokenIn).approve(address(sushi_router_v2), _amountIn);

        address[] memory _path = get_path(_tokenIn, _tokenOut);

        uint256 _amountOutMin = get_amounts_out(
            _amountIn,
            _path,
            sushi_router_v2
        );

        sushi_router_v2.swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            _path,
            address(this),
            block.timestamp + 300
        );
    }

    function uni_v2(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) public checking_amount(_tokenIn, _amountIn) {
        IERC20(_tokenIn).approve(address(uni_router_v2), _amountIn);

        address[] memory _path = get_path(_tokenIn, _tokenOut);

        uint256 _amountOutMin = get_amounts_out(
            _amountIn,
            _path,
            uni_router_v2
        );

        uni_router_v2.swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            _path,
            address(this),
            block.timestamp + 300
        );
    }

    function uni_v3(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint24 _fee
    ) public checking_amount(_tokenIn, _amountIn) {
        TransferHelper.safeApprove(_tokenIn, address(uni_router_v3), _amountIn);

        // uint256 _amountOutMinimum = get_amounts_out(
        //     _amountIn,
        //     _path,
        //     uni_router_v3
        // );
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: _fee,
                recipient: address(this),
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        uni_router_v3.exactInputSingle(params);
    }

    function arb_swap(
        address _asset01,
        address _asset02,
        uint256 _amount,
        uint8 _dex_path,
        uint24 _fee
    ) public {
        require(_dex_path < 6, "Invalid dex option for an arbitrage!");
        if (DEX_PATH.UNIV3_UNIV2 == DEX_PATH(_dex_path)) {
            require(
                (_fee == 500) || (_fee == 3000) || (_fee == 10000),
                "Invalid fee for swapping in UniV3"
            );
            uni_v3(_asset01, _asset02, _amount, _fee);
            uni_v2(
                _asset02,
                _asset01,
                IERC20(_asset02).balanceOf(address(this))
            );
        } else if (DEX_PATH.UNIV3_SUSHI == DEX_PATH(_dex_path)) {
            require(
                (_fee == 500) || (_fee == 3000) || (_fee == 10000),
                "Invalid fee for swapping in UniV3"
            );
            uni_v3(_asset01, _asset02, _amount, _fee);
            sushi(
                _asset02,
                _asset01,
                IERC20(_asset02).balanceOf(address(this))
            );
        } else if (DEX_PATH.UNIV2_UNIV3 == DEX_PATH(_dex_path)) {
            require(
                (_fee == 500) || (_fee == 3000) || (_fee == 10000),
                "Invalid fee for swapping in UniV3"
            );
            uni_v2(_asset01, _asset02, _amount);
            uni_v3(
                _asset02,
                _asset01,
                IERC20(_asset02).balanceOf(address(this)),
                _fee
            );
        } else if (DEX_PATH.SUSHI_UNIV3 == DEX_PATH(_dex_path)) {
            require(
                (_fee == 500) || (_fee == 3000) || (_fee == 10000),
                "Invalid fee for swapping in UniV3"
            );
            sushi(_asset01, _asset02, _amount);
            uni_v3(
                _asset02,
                _asset01,
                IERC20(_asset02).balanceOf(address(this)),
                _fee
            );
        } else if (DEX_PATH.UNIV2_SUSHI == DEX_PATH(_dex_path)) {
            uni_v2(_asset01, _asset02, _amount);
            sushi(
                _asset02,
                _asset01,
                IERC20(_asset02).balanceOf(address(this))
            );
        } else if (DEX_PATH.SUSHI_UNIV2 == DEX_PATH(_dex_path)) {
            sushi(_asset01, _asset02, _amount);
            uni_v2(
                _asset02,
                _asset01,
                IERC20(_asset02).balanceOf(address(this))
            );
        }
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        arb_swap(
            tokens_addresses[0],
            tokens_addresses[1],
            quantity,
            arb_swap_path,
            fee
        );
        // Approve the LendingPool contract allowance to *pull* the owed amount
        uint256 amountOwing = amount + premium;
        IERC20(asset).approve(address(LENDING_POOL), amountOwing);

        return true;
    }

    function _flashloan(address asset, uint256 amount) internal {
        address receiverAddress = address(this);
        uint16 referralCode = 0;
        bytes memory params = "";

        LENDING_POOL.flashLoanSimple(
            receiverAddress,
            asset,
            amount,
            params,
            referralCode
        );
    }

    // calling flashloan
    function flash_loan(
        address _asset01,
        address _asset02,
        uint256 _amount,
        uint8 _arb_swap_path,
        uint24 _arb_swap_fee
    ) public {
        address[] memory assets = new address[](1);
        assets[0] = _asset01;
        quantity = _amount;
        tokens_addresses = [_asset01, _asset02];
        arb_swap_path = _arb_swap_path;
        fee = _arb_swap_fee;

        _flashloan(assets[0], quantity);
    }
}
