/*
 * Copyright 2023 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

class HTTP: NSObject {
    private static let operationQueue = OperationQueue()

    private static let session: URLSession = .init(configuration: .default,
                                                   delegate: nil,
                                                   delegateQueue: operationQueue)

    public static func requestData(from url: URL) async throws -> Data {
        let request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: .defaultHTTPConnect)
        let (data, _) = try await session.data(for: request)
        return data
    }

    public static func requestString(from url: URL) async throws -> String {
        let data = try await requestData(from: url)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InternalError.state(message: "Failed to convert string")
        }
        return string
    }
}
