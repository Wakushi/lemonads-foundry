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

function getSourceConfig(source) {
  switch (source) {
    case "clicks":
      return {
        source: fs
          .readFileSync("./functions/sources/click-aggregator-source.js")
          .toString(),
        args: ["1724629303"],
      }
    case "notify":
      return {
        source: fs
          .readFileSync("./functions/sources/notification-source.js")
          .toString(),
        args: ["0x35E34708C7361F99041a9b046C72Ea3Fcb29134c", "1"],
      }
  }
}

const activeConfig = getSourceConfig("notify")

const requestConfig = {
  codeLocation: Location.Inline,
  codeLanguage: CodeLanguage.JavaScript,
  source: activeConfig.source,
  secrets: {
    SECRET_KEY: process.env["SECRET_KEY"],
  },
  perNodeSecrets: [],
  walletPrivateKey: process.env["PRIVATE_KEY"],
  args: activeConfig.args,
  expectedReturnType: ReturnType.bytes,
  secretsURLs: [],
}

module.exports = requestConfig
