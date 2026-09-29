//
//  RootTabView.swift
//  DroneCast — Views
//
//  Page order matches the spec's UX flow:
//  [1] Verdict · [2] Factors · [3] Window · [4] Settings
//

import SwiftUI

struct RootTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            VerdictView().tag(0)
            FactorListView().tag(1)
            WindowStripView().tag(2)
            SettingsView().tag(3)
        }
        .tabViewStyle(.verticalPage)
    }
}
