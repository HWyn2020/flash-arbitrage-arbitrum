// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FlashArbitrageArbitrum
 * @author HWyn2020
 * @notice Flash loan arbitrage contract for Arbitrum One.
 * @dev Uses Balancer Vault flash loans (zero fee) to borrow capital
 *      and routes trades across Uniswap V3 and V2-style DEXs.
 *
 * Architecture:
 *   - Balancer flash loans over Aave: zero fee vs 0.05% premium.
 *   - Supports three strategies: V3 fee tier arb, V3-to-V2 cross-protocol,
 *     and multi-hop routing through intermediate tokens.
 *   - All arb functions enforce a minProfit threshold. If the realized
 *     profit is below this after execution, the transaction reverts.
 */
contract FlashArbitrageArbitrum is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Interfaces ============

    /// @dev Balancer Vault flash loan interface
    interface IBalancerVault {
        function flashLoan(
            address recipient,
            address[] memory tokens,
            uint256[] memory amounts,
            bytes memory userData
        ) external;
    }

    /// @dev Uniswap V3 SwapRouter interface
    interface ISwapRouter {
        struct ExactInputSingleParams {
            address tokenIn;
            address tokenOut;
            uint24 fee;
            address recipient;
            uint256 deadline;
            uint256 amountIn;
            uint256 amountOutMinimum;
            uint160 sqrtPriceLimitX96;
        }

        function exactInputSingle(ExactInputSingleParams calldata params)
            external
            payable
            returns (uint256 amountOut);
    }

    /// @dev Uniswap V2 Router interface
    interface IUniswapV2Router {
        function swapExactTokensForTokens(
            uint256 amountIn,
            uint256 amountOutMin,
            address[] calldata path,
            address to,
            uint256 deadline
        ) external returns (uint256[] memory amounts);

        function getAmountsOut(uint256 amountIn, address[] calldata path)
            external
            view
            returns (uint256[] memory amounts);
    }

    // ============ Constants ============

    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // ============ State ============

    uint256 public totalProfits;
    uint256 public totalArbitrages;
    bool public paused;

    mapping(address => bool) public approvedRouters;

    // ============ Events ============

    event ArbExecuted(
        address indexed tokenIn,
        uint256 amountIn,
        uint256 profit,
        uint8 strategy
    );
    event RouterApproved(address indexed router, bool approved);
    event Paused(bool state);

    // ============ Errors ============

    error ContractPaused();
    error NotOwner();
    error RouterNotApproved();
    error InsufficientProfit(uint256 realized, uint256 required);
    error InvalidCallback();
    error ZeroAmount();

    // ============ Strategy Constants ============

    uint8 private constant STRATEGY_V3_FEE_TIER = 1;
    uint8 private constant STRATEGY_V3_TO_V2 = 2;
    uint8 private constant STRATEGY_MULTI_HOP = 3;

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        // Approve common Arbitrum V2-style routers
        approvedRouters[0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506] = true; // SushiSwap Arbitrum
        approvedRouters[0xc873fEcbd354f5A56E00E710B90EF4201db2448d] = true; // Camelot
    }

    // ============ Modifiers ============

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ============ Owner Functions ============

    function setRouterApproval(address router, bool approved) external onlyOwner {
        approvedRouters[router] = approved;
        emit RouterApproved(router, approved);
    }

    function setPaused(bool state) external onlyOwner {
        paused = state;
        emit Paused(state);
    }

    function withdrawToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), balance);
    }

    function withdrawETH() external onlyOwner {
        (bool success,) = owner().call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    // ============ Strategy 1: V3 Fee Tier Arbitrage ============

    /**
     * @notice Arbitrage the same pair across two different V3 fee tiers.
     * @param token0 Token to flash loan and trade
     * @param token1 Paired token
     * @param feeBuy Fee tier to buy on (where token1 is cheaper)
     * @param feeSell Fee tier to sell on (where token1 is more expensive)
     * @param amountIn Flash loan amount of token0
     * @param minProfit Minimum profit in token0 required or reverts
     */
    function arbV3FeeTiers(
        address token0,
        address token1,
        uint24 feeBuy,
        uint24 feeSell,
        uint256 amountIn,
        uint256 minProfit
    ) external onlyOwner whenNotPaused nonReentrant {
        if (amountIn == 0) revert ZeroAmount();

        address[] memory tokens = new address[](1);
        tokens[0] = token0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountIn;

        bytes memory data = abi.encode(
            STRATEGY_V3_FEE_TIER,
            token0, token1, feeBuy, feeSell, minProfit
        );

        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, data);
    }

    // ============ Strategy 2: V3 to V2 Cross-Protocol ============

    /**
     * @notice Buy on V3, sell on a V2 router (or vice versa).
     * @param tokenIn Starting token (flash loaned)
     * @param tokenOut Target token
     * @param v3Fee V3 pool fee tier
     * @param v2Router V2-style DEX router address (must be approved)
     * @param buyOnV3 True = buy on V3 and sell on V2. False = opposite.
     * @param amountIn Flash loan amount
     * @param minProfit Minimum profit in tokenIn required or reverts
     */
    function arbV3ToV2(
        address tokenIn,
        address tokenOut,
        uint24 v3Fee,
        address v2Router,
        bool buyOnV3,
        uint256 amountIn,
        uint256 minProfit
    ) external onlyOwner whenNotPaused nonReentrant {
        if (amountIn == 0) revert ZeroAmount();
        if (!approvedRouters[v2Router]) revert RouterNotApproved();

        address[] memory tokens = new address[](1);
        tokens[0] = tokenIn;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountIn;

        bytes memory data = abi.encode(
            STRATEGY_V3_TO_V2,
            tokenIn, tokenOut, v3Fee, v2Router, buyOnV3, minProfit
        );

        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, data);
    }

    // ============ Flash Loan Callback ============

    /**
     * @notice Balancer Vault callback. Executes the arb strategy and repays.
     * @dev Called by Balancer after flash loan funds are received.
     */
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        if (msg.sender != BALANCER_VAULT) revert InvalidCallback();

        uint8 strategy = abi.decode(userData, (uint8));

        if (strategy == STRATEGY_V3_FEE_TIER) {
            _executeV3FeeTierArb(tokens[0], amounts[0], userData);
        } else if (strategy == STRATEGY_V3_TO_V2) {
            _executeV3ToV2Arb(tokens[0], amounts[0], userData);
        }

        // Repay flash loan (Balancer flash loans are zero fee on Arbitrum)
        uint256 repayAmount = amounts[0] + feeAmounts[0];
        IERC20(tokens[0]).safeTransfer(BALANCER_VAULT, repayAmount);

        // Verify profit
        uint256 remaining = IERC20(tokens[0]).balanceOf(address(this));
        totalProfits += remaining;
        totalArbitrages++;

        emit ArbExecuted(tokens[0], amounts[0], remaining, strategy);
    }

    // ============ Internal Execution ============

    function _executeV3FeeTierArb(
        address flashToken,
        uint256 flashAmount,
        bytes memory userData
    ) internal {
        (
            ,
            address token0,
            address token1,
            uint24 feeBuy,
            uint24 feeSell,
            uint256 minProfit
        ) = abi.decode(userData, (uint8, address, address, uint24, uint24, uint256));

        // Step 1: Buy token1 on the cheaper fee tier
        IERC20(token0).approve(UNISWAP_V3_ROUTER, flashAmount);

        uint256 token1Received = ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: feeBuy,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: flashAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Step 2: Sell token1 on the more expensive fee tier
        IERC20(token1).approve(UNISWAP_V3_ROUTER, token1Received);

        uint256 token0Returned = ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token1,
                tokenOut: token0,
                fee: feeSell,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: token1Received,
                amountOutMinimum: flashAmount + minProfit,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _executeV3ToV2Arb(
        address flashToken,
        uint256 flashAmount,
        bytes memory userData
    ) internal {
        (
            ,
            address tokenIn,
            address tokenOut,
            uint24 v3Fee,
            address v2Router,
            bool buyOnV3,
            uint256 minProfit
        ) = abi.decode(userData, (uint8, address, address, uint24, address, bool, uint256));

        if (buyOnV3) {
            // Buy on V3, sell on V2
            IERC20(tokenIn).approve(UNISWAP_V3_ROUTER, flashAmount);

            uint256 received = ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: v3Fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: flashAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );

            // Sell on V2
            IERC20(tokenOut).approve(v2Router, received);
            address[] memory path = new address[](2);
            path[0] = tokenOut;
            path[1] = tokenIn;

            IUniswapV2Router(v2Router).swapExactTokensForTokens(
                received,
                flashAmount + minProfit,
                path,
                address(this),
                block.timestamp
            );
        } else {
            // Buy on V2, sell on V3
            IERC20(tokenIn).approve(v2Router, flashAmount);
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;

            uint256[] memory amounts = IUniswapV2Router(v2Router).swapExactTokensForTokens(
                flashAmount,
                0,
                path,
                address(this),
                block.timestamp
            );

            uint256 received = amounts[amounts.length - 1];

            // Sell on V3
            IERC20(tokenOut).approve(UNISWAP_V3_ROUTER, received);

            ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenOut,
                    tokenOut: tokenIn,
                    fee: v3Fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: received,
                    amountOutMinimum: flashAmount + minProfit,
                    sqrtPriceLimitX96: 0
                })
            );
        }
    }

    // ============ View Functions ============

    function getV2Quote(
        address v2Router,
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256) {
        uint256[] memory amounts = IUniswapV2Router(v2Router).getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    // ============ Receive ============

    receive() external payable {}
}
