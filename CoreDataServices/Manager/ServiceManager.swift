//
//  ServiceManager.swift
//  CoreDataServices
//
//  Created by William Boles on 31/03/2016.
//  Copyright © 2016 Boles. All rights reserved.
//

import CoreData
import Foundation
import ConvenientFileManager

/**
 A singleton manager that is responsible for setting up a core data stack and providing access to both a main `NSManagedObjectContext` and private `NSManagedObjectContext` context. The implementation of this stack is where mainManagedObjectContext will be the parent of backgroundManagedObjectContext using the newer main/private concurrency solution rather than confinement. When performing Core Data tasks you should use `performBlock` or `performBlockAndWait` to ensure that the context is being used on the correct thread. Please note, that this can lead to performance overhead when compared to alternative stack solutions (http://floriankugler.com/2013/04/29/concurrent-core-data-stack-performance-shootout/) however it is the simplest conceptually to understand.
 */
public class ServiceManager: NSObject {
    
    //MARK: - Accessors

    /// URL of the directory where persistent store's is located.
    private lazy var storeDirectoryURL: URL = {
        let storeDirectoryURL = FileManager.documentsDirectoryURL().appendingPathComponent("persistent-store")
        
        return storeDirectoryURL
    }()
    
    
    /// URL of where persistent store's is located.
    private lazy var storeURL: URL = {
        let modelFileName = self.modelURL?.deletingPathExtension().lastPathComponent
        let storeFilePath = "\(modelFileName!).sqlite"
        
        let storeURL = self.storeDirectoryURL.appendingPathComponent(storeFilePath)
        
        return storeURL
    }()
    
    private var modelURL: URL?
    
    /// Model of the persistent store.
    private var managedObjectModel: NSManagedObjectModel {
        get {
            if _managedObjectModel == nil {
                _managedObjectModel = NSManagedObjectModel(contentsOf: modelURL!)
            }
            
            return _managedObjectModel!
        }
    }
    
    private var _managedObjectModel: NSManagedObjectModel?
    
    /// Persistent store coordinator - responsible for handling communication with the persistent store
    private var persistentStoreCoordinator: NSPersistentStoreCoordinator {
        get {
            if _persistentStoreCoordinator == nil {
                _persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
                
                createPersistentStoreAndAssignToCoordinatorWithDeleteAndRetryOnError(coordinator: _persistentStoreCoordinator!, deleteAndRetry: true)
            }
            
            return _persistentStoreCoordinator!
        }
    }
    
    private var _persistentStoreCoordinator: NSPersistentStoreCoordinator?
    
    /**
     `NSManagedObjectContext` instance that is used as the default context.
     
     This context should be used on the main thread - using concurrancy type: `NSMainQueueConcurrencyType`.
     */
    public var mainManagedObjectContext: NSManagedObjectContext {
        get {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            
            if _mainManagedObjectContext == nil {
                _mainManagedObjectContext = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.mainQueueConcurrencyType)
                
                _mainManagedObjectContext!.persistentStoreCoordinator = persistentStoreCoordinator
            }
            
            return _mainManagedObjectContext!
        }
    }
    
    private var _mainManagedObjectContext: NSManagedObjectContext?
    
    /**
     `NSManagedObjectContext` instance that is used as the background context
     
     This context should be used on a background thread - using concurrancy type: `NSPrivateQueueConcurrencyType`.
     */
    public var backgroundManagedObjectContext: NSManagedObjectContext {
        get {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            
            if _backgroundManagedObjectContext == nil {
                _backgroundManagedObjectContext = NSManagedObjectContext(concurrencyType: NSManagedObjectContextConcurrencyType.privateQueueConcurrencyType)
                
                _backgroundManagedObjectContext!.parent = mainManagedObjectContext
                _backgroundManagedObjectContext!.undoManager = nil
            }
            
            return _backgroundManagedObjectContext!
        }
    }
    
    private var _backgroundManagedObjectContext: NSManagedObjectContext?
    
    //MARK: - SharedInstance
    
    /**
     Returns the global ServiceManager instance.
     
     - Returns: ServiceManager shared instance.
     */
    public static let sharedInstance = ServiceManager()
    
    //MARK: - SetUp
    
    /**
     Sets Up the core data stack using a model with the filename.
     
     - Parameter name: filename of the model to load.
     */
    public func setupModel(name: String) {
        setupModel(name: name, bundle: Bundle.main)
    }
    
    /**
     Sets Up the core data stack using a model with the filename.
     
     - Parameter name: filename of the model to load.
     - Parameter bundle: bundle the model is in.
     */
    public func setupModel(name: String, bundle: Bundle) {
        modelURL = bundle.url(forResource: name, withExtension: "momd")
    }
    
    //MARK: - PersistentStore
    
    /**
     Will attempt to create the persistent store and assign that persistent store to the coordinator.
     
     - Parameter deleteAndRetry: will delete the current persistent store and try creating it fresh. This can happen where lightweight migration has failed.
     */
    private func createPersistentStoreAndAssignToCoordinatorWithDeleteAndRetryOnError(coordinator: NSPersistentStoreCoordinator, deleteAndRetry: Bool) {
        var directoryCreated = true
        
        //Creating an additional directory so that when we clear we get all the files connected to Core Data
        if !FileManager.fileExists(absolutePath: storeDirectoryURL.path) {
            directoryCreated = FileManager.createDirectory(absoluteDirectoryPath: storeDirectoryURL.path)
        }
        
        if directoryCreated {
            var options = Dictionary<String, Bool>()
            options[NSMigratePersistentStoresAutomaticallyOption] = true
            options[NSInferMappingModelAutomaticallyOption] = true
            
            do {
                try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
            } catch {
                if  deleteAndRetry {
                    print("Unresolved persistent store error: \(error)")
                    print("Deleting and retrying")
                    
                    deletePersistentStore()
                    createPersistentStoreAndAssignToCoordinatorWithDeleteAndRetryOnError(coordinator: coordinator, deleteAndRetry: false)
                } else {
                    print("Serious error with persistent store: \(error)")
                }
            }
        } else {
            print("Unable to persistentstore due to directory issue")
        }
    }
    
    /**
     Deletes the persistent store from the file system.
     */
    private func deletePersistentStore() {
        //Need to delete the directory so that we also get the `-shm` and `-wal` files
        FileManager.deleteData(absolutePath: storeDirectoryURL.path)
    }
    
    //MARK: - Clear
    
    /**
     Destroys all data from core data and tears down the stack.
     */
    public func clear() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        _mainManagedObjectContext = nil
        _backgroundManagedObjectContext = nil
        
        _persistentStoreCoordinator = nil
        _managedObjectModel = nil
        
        deletePersistentStore()
    }
    
    //MARK: - Save
    
    /**
     Saves the managed object context that is used via the `mainManagedObjectContext` var.
     */
    public func saveMainManagedObjectContext() {
        mainManagedObjectContext.performAndWait({
            self.mainManagedObjectContext.saveAndForcePushChangesIfNeeded()
        })
    }
    
    /**
     Saves the managed object context that is set used the `NSPrivateQueueConcurrencyType` type.
     
     Saving the backgroundManagedObjectContext will cause the mainManagedObjectContext to be saved. This can result in a slightly longer save operation however the trade-off is to ensure "data correctness" over performance.
     */
    public func saveBackgroundManagedObjectContext() {
        backgroundManagedObjectContext.performAndWait({
            self.backgroundManagedObjectContext.saveAndForcePushChangesIfNeeded()
        })
    }
}
