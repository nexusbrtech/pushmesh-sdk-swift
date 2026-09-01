#!/usr/bin/env swift
// Servidor HTTP mínimo em loopback para observar o que o SDK manda — a prova
// de fronteira do laboratório sem depender de credencial nenhuma.
//
//   swift Exemplo/servidor-local.swift [porta]     # porta padrão 8787
//
// Loga cada pedido (método, caminho, corpo JSON) e responde o contrato:
// POST /players → {"id": "..."}, o resto → {"ok": true}.
//
// Duas lições da suíte de testes que moram aqui de propósito: ler HTTP com
// `receive` em loop até \r\n\r\n + Content-Length (receiveMessage só entrega
// quando o peer FECHA); e nada de achar que 127.0.0.1 do simulador é outro
// host — é o Mac.

import Foundation
import Network

setbuf(stdout, nil)
let porta = UInt16(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8787") ?? 8787

let fila = DispatchQueue(label: "io.pushmesh.lab.servidor", attributes: .concurrent)
let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: porta)!)
let listener = try NWListener(using: params)
let pronto = DispatchSemaphore(value: 0)
var playerId = "lab-" + UUID().uuidString

listener.stateUpdateHandler = { s in if case .ready = s { pronto.signal() } }
listener.newConnectionHandler = { conexao in
  conexao.start(queue: fila)
  ler(conexao, Data())
}
listener.start(queue: fila)
guard pronto.wait(timeout: .now() + 5) == .success else {
  print("[lab] listener não subiu na porta \(porta)"); exit(1)
}
print("[lab] ouvindo em http://127.0.0.1:\(porta)")

func ler(_ conexao: NWConnection, _ acumulado: Data) {
  conexao.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { dados, _, fim, erro in
    var acumulado = acumulado
    if let dados { acumulado.append(dados) }
    if let faixa = acumulado.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])),
       requestCompleto(acumulado, faixa) {
      let cabecalho = String(data: acumulado[..<faixa.lowerBound], encoding: .utf8) ?? ""
      let primeira = cabecalho.components(separatedBy: "\r\n").first ?? ""
      let corpo = String(data: acumulado[faixa.upperBound...], encoding: .utf8) ?? ""
      let partes = primeira.split(separator: " ")
      let metodo = partes.count > 0 ? String(partes[0]) : "?"
      let caminho = partes.count > 1 ? String(partes[1]) : "?"
      print("[lab] \(metodo) \(caminho) corpo=\(corpo)")
      let resposta: String
      if caminho.hasSuffix("/players"), metodo == "POST" {
        resposta = "HTTP/1.1 200 OK\r\nContent-Length: \(playerId.utf8.count + 9)\r\nConnection: close\r\n\r\n{\"id\":\"\(playerId)\"}"
      } else {
        let corpo = "{\"ok\":true}"
        resposta = "HTTP/1.1 200 OK\r\nContent-Length: \(corpo.utf8.count)\r\nConnection: close\r\n\r\n\(corpo)"
      }
      conexao.send(content: resposta.data(using: .utf8), completion: .contentProcessed { _ in })
      return
    }
    if erro == nil && !fim { ler(conexao, acumulado); return }
    conexao.cancel()
  }
}

/// Fim de cabeçalho + Content-Length do corpo satisfeito — sem isto o log
/// mentiria: cabeçalho e corpo chegam em receives separados.
func requestCompleto(_ dados: Data, _ faixa: Range<Data.Index>) -> Bool {
  let cabecalho = String(data: dados[..<faixa.lowerBound], encoding: .utf8) ?? ""
  let corpoEsperado = cabecalho
    .components(separatedBy: "\r\n")
    .compactMap { linha -> Int? in
      let partes = linha.split(separator: ":", maxSplits: 1)
      guard partes.count == 2, partes[0].lowercased() == "content-length" else { return nil }
      return Int(partes[1].trimmingCharacters(in: .whitespaces))
    }
    .first ?? 0
  return dados.count - faixa.upperBound >= corpoEsperado
}

// Mantém o processo vivo.
dispatchMain()
