const fs = require("fs")

require("@chainlink/env-enc").config()

const Location = {
  Inline: 0,
  Remote: 1,
}

const CodeLanguage = {
  JavaScript: 0,
}

const ReturnType = {
  uint: "uint256",
  uint256: "uint256",
  int: "int256",
  int256: "int256",
  string: "string",
  bytes: "Buffer",
  Buffer: "Buffer",
}

function getSourceConfig() {
  return {
    source: fs
      .readFileSync("./functions/sources/firebase-source.js")
      .toString(),
    args: ["1724629303"],
  }
}

const activeConfig = getSourceConfig()

const requestConfig = {
  codeLocation: Location.Inline,
  codeLanguage: CodeLanguage.JavaScript,
  source: activeConfig.source,
  secrets: {},
  perNodeSecrets: [],
  walletPrivateKey: process.env["PRIVATE_KEY"],
  args: activeConfig.args,
  expectedReturnType: ReturnType.bytes,
  secretsURLs: [],
}

module.exports = requestConfig
