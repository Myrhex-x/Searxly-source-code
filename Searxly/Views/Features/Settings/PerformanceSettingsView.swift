//
//  PerformanceSettingsView.swift
//  Searxly
//

import SwiftUI

struct PerformanceSettingsView: View {
    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Performance",
                subtitle: Edition.isMaximum
                    ? "Memory and tab-lifecycle management. Performance options never trade away protection."
                    : "Save memory and keep your tab list manageable. Both are optional."
            )

            SettingsSection(
                title: "Tab hibernation",
                footer: "Unloads background tabs from memory. They reload instantly when you switch back."
            ) {
                SettingsToggleRow(
                    title: "Hibernate inactive tabs",
                    description: "Frees RAM by unloading tabs you have not used recently.",
                    isOn: Binding(
                        get: { TabHibernationManager.shared.isEnabled },
                        set: { TabHibernationManager.shared.isEnabled = $0 }
                    )
                )

                if TabHibernationManager.shared.isEnabled {
                    SettingsDivider()

                    Stepper(
                        "Keep \(TabHibernationManager.shared.maxActiveTabs) tabs in memory",
                        value: Binding(
                            get: { TabHibernationManager.shared.maxActiveTabs },
                            set: { TabHibernationManager.shared.maxActiveTabs = $0 }
                        ),
                        in: 3...20
                    )
                    .font(.subheadline)

                    SettingsPickerRow(
                        title: "Hibernate after",
                        selection: Binding(
                            get: { Int(TabHibernationManager.shared.inactivityTimeout) },
                            set: { TabHibernationManager.shared.inactivityTimeout = TimeInterval($0) }
                        )
                    ) {
                        Picker("", selection: Binding(
                            get: { Int(TabHibernationManager.shared.inactivityTimeout) },
                            set: { TabHibernationManager.shared.inactivityTimeout = TimeInterval($0) }
                        )) {
                            Text("5 minutes").tag(300)
                            Text("10 minutes").tag(600)
                            Text("15 minutes").tag(900)
                            Text("30 minutes").tag(1800)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }

            SettingsSection(
                title: "Tab cleanup",
                footer: "Closes tabs entirely — more aggressive than hibernation."
            ) {
                let cleanup = TabCleanupManager.shared

                SettingsToggleRow(
                    title: "Automatically close old tabs",
                    description: "Removes stale or excess tabs from your session.",
                    isOn: Binding(
                        get: { cleanup.isEnabled },
                        set: {
                            cleanup.isEnabled = $0
                            cleanup.saveConfiguration()
                        }
                    )
                )

                if cleanup.isEnabled {
                    SettingsDivider()

                    SettingsPickerRow(
                        title: "Close standard tabs after",
                        selection: Binding(
                            get: { Int(cleanup.closeUnusedAfter) },
                            set: {
                                cleanup.closeUnusedAfter = TimeInterval($0)
                                cleanup.saveConfiguration()
                            }
                        )
                    ) {
                        Picker("", selection: Binding(
                            get: { Int(cleanup.closeUnusedAfter) },
                            set: {
                                cleanup.closeUnusedAfter = TimeInterval($0)
                                cleanup.saveConfiguration()
                            }
                        )) {
                            Text("Never").tag(0)
                            Text("1 hour").tag(3600)
                            Text("4 hours").tag(14400)
                            Text("12 hours").tag(43200)
                            Text("1 day").tag(86400)
                            Text("1 week").tag(604800)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    SettingsPickerRow(
                        title: "Close Private tabs after",
                        selection: Binding(
                            get: { Int(cleanup.closePrivateAfter) },
                            set: {
                                cleanup.closePrivateAfter = TimeInterval($0)
                                cleanup.saveConfiguration()
                            }
                        )
                    ) {
                        Picker("", selection: Binding(
                            get: { Int(cleanup.closePrivateAfter) },
                            set: {
                                cleanup.closePrivateAfter = TimeInterval($0)
                                cleanup.saveConfiguration()
                            }
                        )) {
                            Text("15 minutes").tag(900)
                            Text("30 minutes").tag(1800)
                            Text("1 hour").tag(3600)
                            Text("4 hours").tag(14400)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    SettingsPickerRow(
                        title: "Limit total tabs to",
                        selection: Binding(
                            get: { cleanup.closeWhenExceedsCount },
                            set: {
                                cleanup.closeWhenExceedsCount = $0
                                cleanup.saveConfiguration()
                            }
                        )
                    ) {
                        Picker("", selection: Binding(
                            get: { cleanup.closeWhenExceedsCount },
                            set: {
                                cleanup.closeWhenExceedsCount = $0
                                cleanup.saveConfiguration()
                            }
                        )) {
                            Text("No limit").tag(0)
                            Text("15").tag(15)
                            Text("20").tag(20)
                            Text("25").tag(25)
                            Text("30").tag(30)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    SettingsToggleRow(
                        title: "Close background tabs on quit",
                        description: "Your front tab stays open for the next launch.",
                        isOn: Binding(
                            get: { cleanup.closeBackgroundTabsOnQuit },
                            set: {
                                cleanup.closeBackgroundTabsOnQuit = $0
                                cleanup.saveConfiguration()
                            }
                        )
                    )
                }
            }
        }
    }
}