//
//  Shareinator.swift
//  PartyUI
//
//  Created by lunginspector on 2/12/26.
//

import Foundation
import UIKit

@MainActor
public func presentShareSheet(with url: URL) {
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first,
       var topController = window.rootViewController {
        
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }
        
        let activityViewController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityViewController.popoverPresentationController {
            let sourceView = topController.view!
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(
                x: sourceView.bounds.midX,
                y: sourceView.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        topController.present(activityViewController, animated: true)
    }
}

