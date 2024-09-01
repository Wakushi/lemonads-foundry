const { SecretsManager } = require("@chainlink/functions-toolkit")
const ethers = require("ethers")
require("@chainlink/env-enc").config()

const uploadSecrets = async () => {
  // hardcoded for BASE SEPOLIA DON
  const routerAddress = "0xf9B8fc078197181C841c296C876945aaa425B278"
  const donId = "fun-base-sepolia-1"
  const gatewayUrls = [
    "https://01.functions-gateway.testnet.chain.link/",
    "https://02.functions-gateway.testnet.chain.link/",
  ]

  const privateKey = process.env.PRIVATE_KEY
  if (!privateKey)
    throw new Error(
      "private key not provided - check your environment variables"
    )

  const rpcUrl = process.env.BASE_SEPOLIA_RPC_URL

  if (!rpcUrl)
    throw new Error(`rpcUrl not provided  - check your environment variables`)

  const secrets = {
    SECRET_KEY: process.env.SECRET_KEY,
  }
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl)
  const wallet = new ethers.Wallet(privateKey)
  const signer = wallet.connect(provider)

  const secretsManager = new SecretsManager({
    signer: signer,
    functionsRouterAddress: routerAddress,
    donId: donId,
  })
  await secretsManager.initialize()

  const encryptedSecretsObj = await secretsManager.encryptSecrets(secrets)
  const slotIdNumber = 0
  const expirationTimeMinutes = 2880 // 2 days

  console.log(
    `Upload encrypted secret to gateways ${gatewayUrls}. slotId ${slotIdNumber}. Expiration in minutes: ${expirationTimeMinutes}`
  )

  const uploadResult = await secretsManager.uploadEncryptedSecretsToDON({
    encryptedSecretsHexstring: encryptedSecretsObj.encryptedSecrets,
    gatewayUrls: gatewayUrls,
    slotId: slotIdNumber,
    minutesUntilExpiration: expirationTimeMinutes,
  })

  if (!uploadResult.success)
    throw new Error(`Encrypted secrets not uploaded to ${gatewayUrls}`)

  console.log(
    `\n✅ Secrets uploaded properly to gateways ${gatewayUrls}! Gateways response: `,
    uploadResult
  )

  console.log("\nUploaded secrets to DON...")
  const encryptedSecretsReference =
    secretsManager.buildDONHostedEncryptedSecretsReference({
      slotId: slotIdNumber,
      version: uploadResult.version,
    })

  console.log(
    `\nMake a note of the encryptedSecretsReference: ${encryptedSecretsReference} `
  )

  const donHostedSecretsVersion = parseInt(uploadResult.version)
  console.log(`\n✅ Secrets version: ${donHostedSecretsVersion}`)
}

uploadSecrets().catch((e) => {
  console.error(e)
  process.exit(1)
})
