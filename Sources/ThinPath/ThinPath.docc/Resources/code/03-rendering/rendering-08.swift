import UIKit
import ThinPath

final class GalleryViewController: UIViewController {
    private let svgView = SVGView()

    override func viewDidLoad() {
        super.viewDidLoad()

        svgView.frame = CGRect(x: 20, y: 80, width: 200, height: 200)
        svgView.backgroundColor = .clear
        view.addSubview(svgView)

        svgView.document = SVGLoader.fromBundle("logo")
    }
}
