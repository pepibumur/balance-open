//
//  KrakenAPIClient.swift
//  Balance
//
//  Created by Red Davis on 15/09/2017.
//  Copyright © 2017 Balanced Software, Inc. All rights reserved.
//

import Foundation


internal final class KrakenAPIClient
{
    // Internal
    internal var credentials: Credentials?
    
    // Private
    private let session: URLSession
    private let baseURL = URL(string: "https://api.kraken.com")!
    
    // MARK: Initialization
    
    internal required init(session: URLSession)
    {
        self.session = session
    }
    
    internal convenience init()
    {
        self.init(session: certValidatedSession)
    }
}

// MARK: Wallets

internal extension KrakenAPIClient
{
    private func generateAccountRequest(credentials: Credentials?) throws -> URLRequest {
        
        guard let unwrappedCredentials = credentials else
        {
            throw APICredentialsComponents.Error.noCredentials
        }
        
        let requestPath = "/0/private/Balance"
        
        let nonce = String(Int(Date().timeIntervalSinceReferenceDate.rounded() * 1000))
        let body = [
            "nonce" : nonce
            ].httpFormEncode()
        
        let headers = try AuthHeaders(credentials: unwrappedCredentials, requestPath: requestPath, nonce: nonce, body: body)
        let url = self.baseURL.appendingPathComponent(requestPath)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.add(headers: headers.dictionary)
        
        return request
    }
    
    
    internal func fetchAccounts(_ completionHandler: @escaping (_ accounts: [Account]?, _ error: Error?) -> Void) throws
    {
        let request = try self.generateAccountRequest(credentials: self.credentials)

        // Perform request
        let task = self.session.dataTask(with: request) { (data, response, error) in
            guard let httpResponse = response as? HTTPURLResponse,
                  let unwrappedData = data,
                  let json = try? JSONSerialization.jsonObject(with: unwrappedData, options: []) else
            {
                completionHandler(nil, APIError.invalidJSON)
                return
            }
            
            if case 200...299 = httpResponse.statusCode {
                guard let responseJSON = json as? [String : Any],
                      let resultJSON = responseJSON["result"] as? [String : String] else
                {
                    completionHandler(nil, APIError.invalidJSON)
                    return
                }
                
                // Build accounts
                var accounts = [KrakenAPIClient.Account]()
                for (currency, balance) in resultJSON
                {
                    do
                    {
                        // NOTE: Kraken standardizes all of their currency codes to 4 characters for some reason
                        // so for example LTC is XLTC, USD is ZUSD, but USDT is just USDT. So we need to remove
                        // the trailing characters. It appears that X is for crypto and Z is for fiat.
                        
                        // TODO: Right now, we're safe just removing trailing Z and X characters. However, in the
                        // future, if there is a 4 letter symbol for a currency and it starts with X or Z, we will
                        // run into issues. Thankfully they use XZEC for ZCASH tokens.
                        
                        var currencyCode = currency
                        if currency.length == 4 && (currency.hasPrefix("Z") || currency.hasPrefix("X")) {
                            currencyCode = currency.substring(from: 1)
                        }
                        
                        let account = try Account(currency: currencyCode, balance: balance)
                        accounts.append(account)
                    }
                    catch { }
                }
                
                completionHandler(accounts, nil)
            } else if case 400...402 = httpResponse.statusCode {
                let error = APICredentialsComponents.Error.invalidSecret(message: "One or more of your credentials is invalid")
                completionHandler(nil, error)
            } else if case 403...499 = httpResponse.statusCode {
                let error = APICredentialsComponents.Error.missingPermissions
                completionHandler(nil, error)
            } else {
                let error = APIError.response(httpResponse: httpResponse, data: data)
                completionHandler(nil, error)
            }
        }
        
        task.resume()
    }
}

// MARK: ExchangeApi

extension KrakenAPIClient: ExchangeApi {
    func authenticate(secret: String, key: String) {
        assert(false, "implement")
    }
    
    func authenticate(secret: String, key: String, passphrase: String) {
        assert(false, "implement")
    }
    
    func authenticationChallenge(loginStrings: [Field], closeBlock: @escaping (Bool, Error?, Institution?) -> Void) {
        assert(loginStrings.count == 2, "number of auth fields should be 2 for Kraken")

        var secretField: String?
        var keyField: String?

        for field in loginStrings {
            switch field.type {
            case "key":
                keyField = field.value
            case "secret":
                secretField = field.value
            default:
                assert(false, "wrong fields are passed into the Kraken auth, we require secret and key fields and values")
            }
        }

        guard let secret = secretField,
            let key = keyField else {
                assert(false, "wrong fields are passed into the Kraken auth, we require secret and key fields and values")
                closeBlock(false, "wrong fields are passed into the Kraken auth, we require secret and key fields and values", nil)

                return
        }

        do {
            let credentials = try KrakenAPIClient.Credentials(key: key, secret: secret)
            self.credentials = credentials
            let request = try self.generateAccountRequest(credentials: credentials)
            
            // Perform request
            let task = self.session.dataTask(with: request) { (data, response, error) in
                guard let httpResponse = response as? HTTPURLResponse,
                    let unwrappedData = data,
                    let json = try? JSONSerialization.jsonObject(with: unwrappedData, options: [])
                    
                else {
                    async {
                        closeBlock(true, APIError.invalidJSON, nil)
                    }
                    return
                }
                
                if case 200...299 = httpResponse.statusCode {
                    guard let responseJSON = json as? [String : Any],
                        let resultJSON = responseJSON["result"] as? [String : String] else
                    {
                        async {
                            closeBlock(true, APIError.invalidJSON, nil)
                        }
                        return
                    }
                    //make institution
                    let credentialsIdentifier = "main"
                    var institution: Institution
                    institution = InstitutionRepository.si.institution(source: .kraken, sourceInstitutionId: "", name: "Kraken")!
                    institution.accessToken = credentialsIdentifier
                    do {
                        try credentials.save(identifier: credentialsIdentifier)
                    } catch {
                        async {
                            closeBlock(false, error, nil)
                        }
                    }
                    
                    // Build accounts
                    var accounts = [KrakenAPIClient.Account]()
                    for (currency, balance) in resultJSON {
                        do {
                            //refer to Parse Accounts comments
                            var currencyCode = currency
                            if currency.length == 4 && (currency.hasPrefix("Z") || currency.hasPrefix("X")) {
                                currencyCode = currency.substring(from: 1)
                            }
                            
                            let account = try Account(currency: currencyCode, balance: balance)
                            accounts.append(account)
                        } catch { }
                    }
                    for account in accounts {
                        let currentBalance = self.paddedInteger(for: account.balance, currencyCode: account.currencyCode)
                        let availableBalance = currentBalance
                        
                        // Initialize an Account object to insert the record
                        AccountRepository.si.account(institutionId: institution.institutionId, source: institution.source, sourceAccountId: account.currencyCode, sourceInstitutionId: "", accountTypeId: .exchange, accountSubTypeId: nil, name: account.currencyCode, currency: account.currencyCode, currentBalance: currentBalance, availableBalance: availableBalance, number: nil, altCurrency: nil, altCurrentBalance: nil, altAvailableBalance: nil)
                    }
                    async {
                        closeBlock(true, nil, institution)
                    }
                } else if case 400...402 = httpResponse.statusCode {
                    let error = APICredentialsComponents.Error.invalidSecret(message: "One or more of your credentials is invalid")
                    async {
                        closeBlock(false, error, nil)
                    }
                } else if case 403...499 = httpResponse.statusCode {
                    let error = APICredentialsComponents.Error.missingPermissions
                    async {
                        closeBlock(false, error, nil)
                    }
                    
                } else {
                    let error = APIError.response(httpResponse: httpResponse, data: data)
                    async {
                        closeBlock(false, error, nil)
                    }
                    
                }
            }
            
            task.resume()
        }
        catch APICredentialsComponents.Error.invalidSecret {
            // TODO: show alert
            async {
                closeBlock(false, APICredentialsComponents.Error.invalidSecret(message: ""), nil)
            }
        }
        catch {
            // TODO: show alert
            async {
                closeBlock(false, error, nil)
            }
        }
    }
    private func paddedInteger(for amount: Double, currencyCode: String) -> Int {
        let decimals = Currency.rawValue(currencyCode).decimals
        
        var amountDecimal = Decimal(amount)
        amountDecimal = amountDecimal * Decimal(pow(10.0, Double(decimals)))
        
        return (amountDecimal as NSDecimalNumber).intValue
    }
}


// MARK: Institute

internal extension KrakenAPIClient
{
    static let institution = KrakenInstitution()
    
    class KrakenInstitution: ApiInstitution {
        let source: Source = .kraken
        let sourceInstitutionId: String = ""
        
        var currencyCode: String = ""
        var usernameLabel: String = ""
        var passwordLabel: String = ""
        var name: String = "Kraken"
        var products: [String] = []
        var type: String = ""
        var url: String? = "https://www.kraken.com/"
        var fields: [Field]
        
        // MARK: Initialization
        
        init() {
            let keyField = Field(name: "Key", label: "Key", type: "key", value: nil)
            let secretField = Field(name: "Secret", label: "Secret", type: "secret", value: nil)
            self.fields = [keyField, secretField]
        }
    }
}


internal extension Dictionary where Key: StringProtocol, Value: StringProtocol
{
    internal func httpFormEncode() -> String
    {
        var queryItems = [URLQueryItem]()
        for (key, value) in self
        {
            let queryItem = URLQueryItem(name: String(key), value: String(value))
            queryItems.append(queryItem)
        }
        
        var urlComponents = URLComponents()
        urlComponents.queryItems = queryItems
        
        return urlComponents.url?.query ?? ""
    }
}
