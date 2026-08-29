import AppKit
import AVFoundation
import AVKit
import QuickLookUI
import SwiftUI

@main
struct LocalWebShareMacApp: App {
    @StateObject private var fileStore = FileStore()
    @StateObject private var webServer = LocalWebServer()
    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(fileStore)
                .environmentObject(webServer)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

struct MacContentView: View {
    @EnvironmentObject private var fileStore: FileStore
    @EnvironmentObject private var webServer: LocalWebServer
    @AppStorage("actionLabelMode") private var actionLabelModeRaw = ActionLabelMode.compact.rawValue
    @State private var selectedFile: SharedFile?
    @State private var deleteCandidate: SharedFile?
    @State private var isDropTargeted = false

    private var mode: ActionLabelMode { ActionLabelMode(rawValue: actionLabelModeRaw) ?? .compact }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                appHeader
                sharingCard
                importCard
                Picker("Buttons", selection: $actionLabelModeRaw) {
                    ForEach(ActionLabelMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Spacer()
                Text("Shared folder").font(.caption).foregroundStyle(.secondary)
                Text(FileStore.documentsDirectory.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                Text("Version \(appVersion)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(20)
            .navigationSplitViewColumnWidth(min: 270, ideal: 310)
        } detail: { filesPane }
        .sheet(item: $selectedFile) { file in
            MacMediaGallery(files: fileStore.files, initialFile: file) { deleted in fileStore.delete(deleted) }
                .frame(minWidth: 760, minHeight: 560)
        }
        .confirmationDialog(deleteCandidate.map { "Delete \($0.name)?" } ?? "Delete file?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate=nil } })) {
            Button("Delete", role: .destructive) { if let f=deleteCandidate { fileStore.delete(f) }; deleteCandidate=nil }
            Button("Cancel", role: .cancel) { deleteCandidate=nil }
        }
    }

    private var appHeader: some View {
        HStack(spacing:12) {
            if let image=Bundle.main.url(forResource:"shar-logo-1024",withExtension:"png").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage:image).resizable().scaledToFit().frame(width:58,height:58).clipShape(RoundedRectangle(cornerRadius:12))
            }
            VStack(alignment:.leading,spacing:2){Text("Local Web Share").font(.title2.bold());Text("Wi-Fi media sharing").foregroundStyle(.secondary)}
        }
    }

    private var sharingCard: some View {
        GroupBox("Wi-Fi Sharing") {
            VStack(alignment:.leading,spacing:10) {
                HStack { Circle().fill(webServer.isRunning ? Color.green : Color.secondary).frame(width:10,height:10); Text(webServer.isRunning ? "Sharing is ON":"Sharing is OFF").fontWeight(.semibold) }
                Text(webServer.statusMessage).font(.caption).foregroundStyle(.secondary)
                if webServer.isRunning {
                    Text(webServer.shareURL).font(.body.monospaced()).textSelection(.enabled)
                    HStack {
                        MacActionButton(full:"Copy Address",short:"Copy",icon:"doc.on.doc",mode:mode) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(webServer.shareURL,forType:.string) }
                        MacActionButton(full:"Open in Browser",short:"Open",icon:"safari",mode:mode) { if let url=URL(string:webServer.shareURL){NSWorkspace.shared.open(url)} }
                    }
                }
                MacActionButton(full:webServer.isRunning ? "Stop Sharing":"Start Sharing",short:webServer.isRunning ? "Stop":"Start",icon:webServer.isRunning ? "stop.fill":"play.fill",mode:mode) { webServer.isRunning ? webServer.stop() : webServer.start() }
                    .buttonStyle(.borderedProminent)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,4)
        }
    }

    private var importCard: some View {
        GroupBox("Import") {
            VStack(spacing:8) {
                Image(systemName:"square.and.arrow.down.on.square").font(.system(size:30));Text("Drop files here").fontWeight(.semibold);Text("They are copied into Local Web Share immediately.").font(.caption).foregroundStyle(.secondary)
                MacActionButton(full:"Choose Files…",short:"Choose",icon:"plus",mode:mode){chooseFiles()}
            }
            .frame(maxWidth:.infinity).padding(.vertical,16).background(isDropTargeted ? Color.accentColor.opacity(0.12):Color.clear).clipShape(RoundedRectangle(cornerRadius:10))
            .dropDestination(for:URL.self){urls,_ in urls.forEach{fileStore.importFile(from:$0)};return !urls.isEmpty} isTargeted:{isDropTargeted=$0}
        }
    }

    private var filesPane: some View {
        VStack(spacing:0) {
            HStack { Text("Files").font(.title2.bold());Text("\(fileStore.files.count)").foregroundStyle(.secondary);Spacer();MacActionButton(full:"Show Folder",short:"Folder",icon:"folder",mode:mode){NSWorkspace.shared.open(FileStore.documentsDirectory)};MacActionButton(full:"Refresh",short:"Refresh",icon:"arrow.clockwise",mode:mode){fileStore.refresh()} }.padding(18)
            Divider()
            if fileStore.files.isEmpty { ContentUnavailableView("No Files Yet",systemImage:"folder",description:Text("Drop files into this window or upload them from the browser.")) }
            else {
                List(fileStore.files) { file in
                    HStack(spacing:12) {
                        MacThumbnail(file:file)
                        VStack(alignment:.leading,spacing:4) {
                            Text(file.name).fontWeight(.medium)
                            MacAudioMetadataLine(file:file)
                            Text("\(file.mediaKind.rawValue.capitalized) • \(ByteCountFormatter.string(fromByteCount:file.size,countStyle:.file))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if file.mediaKind == .audio { MacInlineAudioButton(file:file) }
                        MacActionButton(full:"Preview",short:"View",icon:"eye",mode:mode){selectedFile=file}.buttonStyle(.borderless)
                        MacActionButton(full:"Delete",short:"Del",icon:"trash",mode:mode){deleteCandidate=file}.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle()).onTapGesture(count:2){selectedFile=file}
                    .contextMenu { Button("Preview"){selectedFile=file};Button("Reveal in Finder"){NSWorkspace.shared.activateFileViewerSelecting([file.url])};Divider();Button("Delete",role:.destructive){deleteCandidate=file} }
                    .padding(.vertical,3)
                }.listStyle(.inset)
            }
        }
    }

    private func chooseFiles(){let p=NSOpenPanel();p.canChooseFiles=true;p.canChooseDirectories=false;p.allowsMultipleSelection=true;if p.runModal() == .OK {p.urls.forEach{fileStore.importFile(from:$0)}}}
    private var appVersion:String {"\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "?"))"}
}

private struct MacActionButton: View {
    let full:String;let short:String;let icon:String;let mode:ActionLabelMode;let action:()->Void
    var body: some View { Button(action:action){switch mode{case .text:Text(full);case .icons:Image(systemName:icon).accessibilityLabel(full);case .compact:Label(short,systemImage:icon)}} }
}

private struct MacThumbnail: View {
    let file:SharedFile
    var body: some View { ZStack { RoundedRectangle(cornerRadius:9).fill(.quaternary);if let image=thumbnail {Image(nsImage:image).resizable().scaledToFill()}else{Image(systemName:file.systemImageName).font(.title2).foregroundStyle(.secondary)}}.frame(width:54,height:54).clipShape(RoundedRectangle(cornerRadius:9)).overlay(alignment:.bottomTrailing){Text(file.typeLabel).font(.system(size:8,weight:.semibold)).padding(.horizontal,4).padding(.vertical,2).background(.ultraThinMaterial,in:Capsule()).padding(3)} }
    private var thumbnail:NSImage? { if file.mediaKind == .image {return NSImage(contentsOf:file.url)};if file.mediaKind == .audio,let d=MediaMetadataReader.read(file.url).artworkData{return NSImage(data:d)};return nil }
}

private struct MacAudioMetadataLine: View {
    let file:SharedFile
    var body: some View { if file.mediaKind == .audio { let m=MediaMetadataReader.read(file.url);if m.title != nil || m.artist != nil {Text([m.title,m.artist].compactMap{$0}.joined(separator:" — ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)}} }
}

private struct MacInlineAudioButton: View {
    let file:SharedFile;@State private var player:AVPlayer?;@State private var playing=false
    var body: some View { Button{if player==nil{player=AVPlayer(url:file.url)};guard let p=player else{return};playing ? p.pause():p.play();playing.toggle()}label:{Image(systemName:playing ? "pause.circle.fill":"play.circle.fill").font(.title2)}.buttonStyle(.borderless).onDisappear{player?.pause()} }
}

private struct MacMediaGallery: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files:[SharedFile];@State private var index:Int;@State private var confirmDelete=false
    let onDelete:(SharedFile)->Void
    init(files:[SharedFile],initialFile:SharedFile,onDelete:@escaping(SharedFile)->Void){_files=State(initialValue:files);_index=State(initialValue:files.firstIndex(of:initialFile) ?? 0);self.onDelete=onDelete}
    private var file:SharedFile?{files.indices.contains(index) ? files[index]:nil}
    var body: some View { VStack(spacing:0){HStack{Button{prev()}label:{Image(systemName:"chevron.left")}.disabled(index<=0);Button{next()}label:{Image(systemName:"chevron.right")}.disabled(index>=files.count-1);Text(file?.name ?? "Preview").font(.headline).lineLimit(1);Spacer();Text(files.isEmpty ? "":"\(index+1) / \(files.count)").foregroundStyle(.secondary);if let f=file{Button("Reveal"){NSWorkspace.shared.activateFileViewerSelecting([f.url])};Button(role:.destructive){confirmDelete=true}label:{Image(systemName:"trash")}};Button("Done"){dismiss()}}.padding(14);Divider();if let f=file{MacPreviewContent(file:f).id(f.id).simultaneousGesture(DragGesture(minimumDistance:35).onEnded{v in if v.translation.width < -60 {next()} else if v.translation.width > 60 {prev()}})}else{ContentUnavailableView("No Files",systemImage:"folder")}}.confirmationDialog(file.map{"Delete \($0.name)?"} ?? "Delete file?",isPresented:$confirmDelete){Button("Delete",role:.destructive){deleteCurrent()};Button("Cancel",role:.cancel){}} }
    private func prev(){if index>0{index-=1}};private func next(){if index+1<files.count{index+=1}};private func deleteCurrent(){guard let f=file else{return};onDelete(f);files.remove(at:index);if files.isEmpty{dismiss()}else if index>=files.count{index=files.count-1}}
}

private struct MacPreviewContent: View {
    let file:SharedFile;@State private var player:AVPlayer?
    init(file:SharedFile){self.file=file;_player=State(initialValue:file.isPlayableMedia ? AVPlayer(url:file.url):nil)}
    var body: some View { Group { switch file.mediaKind {case .image:if let i=NSImage(contentsOf:file.url){ScrollView([.horizontal,.vertical]){Image(nsImage:i).resizable().scaledToFit().padding(16)}.background(Color.black)}else{unavailable};case .video:if let player{VideoPlayer(player:player).onAppear{player.play()}};case .audio:VStack(spacing:20){Spacer();MacThumbnail(file:file).scaleEffect(3);let m=MediaMetadataReader.read(file.url);Text(m.title ?? file.name).font(.title3.bold());if let a=m.artist{Text(a).foregroundStyle(.secondary)};if let player{MacAudioControls(player:player)};Spacer()}.padding(28);case .document,.file:MacQuickLook(url:file.url)}}.frame(maxWidth:.infinity,maxHeight:.infinity).onDisappear{player?.pause()} }
    private var unavailable:some View{ContentUnavailableView("Cannot Preview",systemImage:"doc.questionmark")}
}

private struct MacAudioControls: View {
    let player:AVPlayer;@State private var isPlaying=false;@State private var current=0.0;@State private var duration=0.0;@State private var observer:Any?
    var body: some View { VStack(spacing:12){Slider(value:Binding(get:{min(current,max(duration,0.01))},set:{current=$0;player.seek(to:CMTime(seconds:$0,preferredTimescale:600))}),in:0...max(duration,0.01));HStack{Text(time(current));Spacer();Button{isPlaying ? player.pause():player.play();isPlaying.toggle()}label:{Image(systemName:isPlaying ? "pause.circle.fill":"play.circle.fill").font(.system(size:48))}.buttonStyle(.plain);Spacer();Text(time(duration))}.font(.caption.monospacedDigit())}.frame(maxWidth:520).onAppear{Task{if let item=player.currentItem,let d=try? await item.asset.load(.duration),d.seconds.isFinite{duration=d.seconds}};observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.25,preferredTimescale:600),queue:.main){t in current=max(0,t.seconds);isPlaying=player.timeControlStatus == .playing};player.play();isPlaying=true}.onDisappear{if let o=observer{player.removeTimeObserver(o);observer=nil};player.pause()} }
    private func time(_ s:Double)->String{guard s.isFinite&&s>=0 else{return"0:00"};let v=Int(s);return String(format:"%d:%02d",v/60,v%60)}
}

private struct MacQuickLook:NSViewRepresentable{let url:URL;func makeNSView(context:Context)->QLPreviewView{let v=QLPreviewView(frame:.zero,style:.normal)!;v.autostarts=true;v.previewItem=url as NSURL;return v};func updateNSView(_ nsView:QLPreviewView,context:Context){nsView.previewItem=url as NSURL}}
