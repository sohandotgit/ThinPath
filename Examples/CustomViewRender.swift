import UIKit
import ThinPath

/// A UIView subclass that renders an SVG document.
class SVGView: UIView {
    var document: SVGDocument?
    private let renderer = ThinPath()

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let document = document else {
            return
        }

        renderer.render(document, into: context, rect: bounds)
    }

    func load(url: URL) {
        let data = try! Data(contentsOf: url)
        let (doc, errors) = parse(data: data)
        if !errors.isEmpty {
            print("Parse errors: \(errors)")
        }
        document = doc
        setNeedsDisplay()
    }
}

/// Usage in a view controller.
class SVGViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let svgView = SVGView(frame: CGRect(x: 0, y: 100, width: 300, height: 300))
        svgView.backgroundColor = .white
        view.addSubview(svgView)

        if let url = Bundle.main.url(forResource: "icon", withExtension: "svg") {
            svgView.load(url: url)
        }
    }
}
