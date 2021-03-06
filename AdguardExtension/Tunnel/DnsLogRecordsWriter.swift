/**
       This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
       Copyright © Adguard Software Limited. All rights reserved.
 
       Adguard for iOS is free software: you can redistribute it and/or modify
       it under the terms of the GNU General Public License as published by
       the Free Software Foundation, either version 3 of the License, or
       (at your option) any later version.
 
       Adguard for iOS is distributed in the hope that it will be useful,
       but WITHOUT ANY WARRANTY; without even the implied warranty of
       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
       GNU General Public License for more details.
 
       You should have received a copy of the GNU General Public License
       along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation 

class DnsLogRecordsWriter: NSObject, DnsLogRecordsWriterProtocol {
    
    var userFilterId: NSNumber?
    var otherFilterIds: [NSNumber]?
    
    var server = ""
    
    private let dnsLogService: DnsLogRecordsServiceProtocol
    private let resources: AESharedResourcesProtocol
    
    var dnsStatisticsService: DnsStatisticsServiceProtocol
    
    private var records = [DnsLogRecord]()
    private var statistics: [DnsStatisticsType : RequestsStatisticsBlock] = [:]
    
    
    private let saveRecordsMinimumTime = 3.0 // seconds
    private let saveStatisticsMinimumTime = 60.0*10.0 // seconds - 10 minutes
    private var nextSaveTime: Double
    private var nextStatisticsSaveTime: Double
    
    private let recordsQueue = DispatchQueue(label: "DnsLogRecordsWriter records queue")
    private let statisticsQueue = DispatchQueue(label: "DnsLogRecordsWriter statistics queue")
    
    @objc init(resources: AESharedResourcesProtocol, dnsLogService: DnsLogRecordsServiceProtocol) {
        self.resources = resources
        self.dnsStatisticsService = DnsStatisticsService(resources: resources)
        self.dnsLogService = dnsLogService
        
        nextSaveTime = Date().timeIntervalSince1970 + saveRecordsMinimumTime
        nextStatisticsSaveTime = Date().timeIntervalSince1970 + saveStatisticsMinimumTime
        
        super.init()
        
        self.loadStatisticsHead()
    }
    
    deinit {
        flush()
    }
    
    func handleEvent(_ event: AGDnsRequestProcessedEvent) {
        if event.error != nil && event.error != "" {
            DDLogError("(DnsLogRecordsWriter) handle event error occured - \(event.error!)")
            return
        }
        
        DDLogInfo("(DnsLogRecordsWriter) handleEvent got answer for domain: \(event.domain ?? "nil") answer: \(event.answer == nil ? "nil" : "nonnil")")
        
        var status: DnsLogRecordStatus
        
        if event.whitelist {
            status = .whitelisted
        }
        else if userFilterId != nil && event.filterListIds.contains(userFilterId!) {
            status = .blacklistedByUserFilter
        }
        else if otherFilterIds?.contains(where: { event.filterListIds.contains($0) }) ?? false {
            status = .blacklistedByOtherFilter
        }
        else {
            status = .processed
        }
        
        let tempRequestsCount = resources.sharedDefaults().integer(forKey: AEDefaultsRequests)
        resources.sharedDefaults().set(tempRequestsCount + 1, forKey: AEDefaultsRequests)
        
        statisticsQueue.async { [weak self] in
            guard let self = self else { return }
            self.statistics[.all]?.numberOfRequests += 1
            
            if (self.isBlocked(event.answer)) {
                let tempBlockedRequestsCount = self.resources.sharedDefaults().integer(forKey: AEDefaultsBlockedRequests)
                self.resources.sharedDefaults().set(tempBlockedRequestsCount + 1, forKey: AEDefaultsBlockedRequests)
                
                self.statistics[.blocked]?.numberOfRequests += 1
            }
        }
        
        let filterIds = event.filterListIds.map { $0.intValue }
        
        let date = Date(timeIntervalSince1970: TimeInterval(event.startTime / 1000))
        
        let record = DnsLogRecord(
            domain: event.domain,
            date: date,
            elapsed: Int(event.elapsed),
            type: event.type,
            answer: event.answer,
            server: server,
            upstreamAddr: event.upstreamAddr,
            bytesSent: Int(event.bytesSent),
            bytesReceived: Int(event.bytesReceived),
            status: status,
            userStatus: .none,
            blockRules: event.rules,
            matchedFilterIds: filterIds,
            originalAnswer: event.originalAnswer,
            answerStatus: event.status
        )
        
        addRecord(record: record)
    }
    
    private func addRecord(record: DnsLogRecord) {
        
        let now = Date().timeIntervalSince1970
        
        recordsQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.records.append(record)
            
            if now < self.nextSaveTime{
                return
            }
            
            self.save()
            self.nextSaveTime = now + self.saveRecordsMinimumTime
        }
        
        statisticsQueue.async { [weak self] in
            guard let self = self else { return }
            if now > self.nextStatisticsSaveTime{
                self.saveStatistics()
            }
        }
    }
    
    private func flush() {
        save()
        saveStatistics()
        resources.sharedDefaults().set(0, forKey: AEDefaultsRequests)
        resources.sharedDefaults().set(0, forKey: AEDefaultsBlockedRequests)
    }
    
    private func save() {
        dnsLogService.writeRecords(records)
        records.removeAll()
    }
    
    private func saveStatistics(){
        let now = Date().timeIntervalSince1970
        dnsStatisticsService.writeStatistics(statistics)
        statistics.removeAll()
        reinitializeStatistics()
        nextStatisticsSaveTime = now + saveStatisticsMinimumTime
    }
    
    private func loadStatisticsHead() {
        
        let all = resources.sharedDefaults().integer(forKey: AEDefaultsRequests)
        let blocked = resources.sharedDefaults().integer(forKey: AEDefaultsBlockedRequests)
        
        let date = Date()
        
        statistics[.all] = RequestsStatisticsBlock(date: date, numberOfRequests: all)
        statistics[.blocked] = RequestsStatisticsBlock(date: date, numberOfRequests: blocked)
    }
    
    private func reinitializeStatistics(){
        let date = Date()
        
        statistics[.all] = RequestsStatisticsBlock(date: date, numberOfRequests: 0)
        statistics[.blocked] = RequestsStatisticsBlock(date: date, numberOfRequests: 0)
        
        resources.sharedDefaults().set(0, forKey: AEDefaultsRequests)
        resources.sharedDefaults().set(0, forKey: AEDefaultsBlockedRequests)
    }
    
    private func isBlocked(_ answer: String?) -> Bool {
        if answer == nil || answer == "" {
            // Mark all NXDOMAIN responses as blocked
            return true
        }

        if answer!.contains("0.0.0.0") ||
            answer!.contains("127.0.0.1") ||
            answer!.contains("[::]")  {
            return true
        }

        return false
    }
}
