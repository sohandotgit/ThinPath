import UIKit
import ThinPath

final class IconViewController: UIViewController {
    private let imageView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let url = Bundle.main.url(forResource: "logo", withExtension: "svg"),
              let svgData = try? Data(contentsOf: url) else {
            return
        }

        let (document, _) = parse(data: svgData)
        let renderer = ThinPath()
    }
}
