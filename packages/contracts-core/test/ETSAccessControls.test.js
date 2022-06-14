const { setup } = require("./setup.js");
const { ethers, upgrades } = require("hardhat");
const { expect } = require("chai");

before("Setup test", async function () {
  [accounts, ETSAccessControls, ETS] = await setup();
});

describe("ETSAccessControls", function () {
  describe("Validate setup/initialization", async function () {
    it("named account ETSAdmin should be admin", async function () {
      expect(await ETSAccessControls.isAdmin(accounts.ETSAdmin.address)).to.be.equal(true);
    });
  });
});

describe("Publisher", async function () {
  it("should admin as contract creator", async function () {
    await ETSAccessControls.grantRole(ethers.utils.id("PUBLISHER"), accounts.ETSPublisher.address);
    expect(await ETSAccessControls.isPublisher(accounts.ETSPublisher.address)).to.be.equal(true);
  });
});