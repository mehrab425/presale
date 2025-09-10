const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const SaleTokenAddress = process.env.SALE_TOKEN || ""; // اگر توکن قبلاً ساخته شده
  if (!SaleTokenAddress) {
    console.log("No SALE_TOKEN set. Deploying an ERC20 mock for testing...");
    const ERC20 = await ethers.getContractFactory("ERC20PresetMinterPauser");
    const token = await ERC20.deploy("Sale Token", "SALE");
    await token.deployed();
    console.log("Deployed mock token at:", token.address);
    process.env.SALE_TOKEN = token.address;
  }

  const saleTokenAddr = process.env.SALE_TOKEN;
  const treasury = process.env.TREASURY;
  const rate = ethers.BigNumber.from("1000"); // مثال: 1000 tokens per wei (تعدیل کن)
  const softCap = ethers.utils.parseEther("10"); // 10 native
  const hardCap = ethers.utils.parseEther("50"); // 50 native
  const now = Math.floor(Date.now()/1000);
  const start = now + 60; // شروع در 1 دقیقه
  const end = now + 86400 * 7; // پایان 7 روز

  const Presale = await ethers.getContractFactory("PresalePro");
  const presale = await Presale.deploy(
    saleTokenAddr,
    treasury,
    rate,
    softCap,
    hardCap,
    start,
    end
  );

  await presale.deployed();
  console.log("Presale deployed at:", presale.address);

  // Deposit sale tokens: محاسبه و واریز توکن‌ها
  const saleToken = await ethers.getContractAt("IERC20", saleTokenAddr);
  const required = ethers.utils.parseUnits("1000000", 18); // مقدار توکنی که باید قرارداد داشته باشه
  // approve then deposit (اگر ERC20 اجازه می‌خواد)
  const txA = await saleToken.connect(deployer).approve(presale.address, required);
  await txA.wait();
  console.log("Approved tokens to presale");

  const txD = await presale.connect(deployer).depositSaleTokens(required);
  await txD.wait();
  console.log("Deposited sale tokens:", required.toString());

  // نمونه تنظیمات: whitelist on, add deployer, set vesting
  await presale.connect(deployer).setWhitelistEnabled(true);
  await presale.connect(deployer).updateWhitelist([deployer.address], true);
  console.log("Whitelist enabled & deployer whitelisted");

  const vestStart = end + 60; // vesting start 1 minute after end
  const cliff = 86400 * 7;    // 7 days cliff
  const duration = 86400 * 30; // 30 days linear vesting
  await presale.connect(deployer).setVestingParams(vestStart, cliff, duration);
  console.log("Vesting params set");

  console.log("Deployment & initial setup completed.");
}

main()
  .then(() => process.exit(0))
  .catch(err => {
    console.error(err);
    process.exit(1);
  });
