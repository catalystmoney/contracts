const { ethers } = require("hardhat");

async function main() {
  // Deploying
  const contract = await ethers.getContractFactory('DummyBUSD');
  const instance = await contract.deploy();
  //const instance = await contract.deploy('0x0a768658eF5a82D7123aa7678345cbef39a157AB', '21600', '1656585900');
  await instance.deployed();
  console.log(instance.address);

  // Upgrading
  //const BoxV2 = await ethers.getContractFactory("BoxV2");
  //const upgraded = await upgrades.upgradeProxy(instance.address, BoxV2);
}

main();