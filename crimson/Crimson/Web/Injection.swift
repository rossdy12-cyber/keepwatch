import Foundation

/// JavaScript snippets Crimson injects into pages for dark-ify and reader mode.
enum Injection {
    /// Force a dark appearance on sites that don't offer one (invert + hue-rotate, images re-inverted).
    static let darkCSS = """
    (function(){
      var id='__crimson_dark__';
      if(document.getElementById(id)) return;
      var s=document.createElement('style'); s.id=id;
      s.textContent='html{filter:invert(1) hue-rotate(180deg) contrast(0.92)!important;background:#0b0b0b!important}'+
        'img,video,picture,canvas,svg,iframe,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}';
      (document.head||document.documentElement).appendChild(s);
    })();
    """

    /// Best-effort reader mode: find the main content and show it on a clean crimson page.
    static let reader = """
    (function(){
      function len(el){return el&&el.innerText?el.innerText.length:0;}
      var best=document.body, score=0;
      var sel='article, main, [role=main], .post, .article, .article-body, .entry-content, #content, .content, .story-body';
      document.querySelectorAll(sel).forEach(function(c){var s=len(c); if(s>score){score=s; best=c;}});
      if(best===document.body){
        document.querySelectorAll('div,section').forEach(function(c){
          if(c.querySelectorAll('p').length>=3){var s=len(c); if(s>score){score=s; best=c;}}
        });
      }
      var title=(document.querySelector('h1')||{}).innerText||document.title||'';
      var css=document.createElement('style');
      css.textContent='body.__cr{all:unset} .__cr-wrap{max-width:40em;margin:0 auto;padding:28px 20px;'+
        'background:#0A0506;color:#F0E6E8;font:18px/1.72 Georgia,"Times New Roman",serif}'+
        '.__cr-wrap h1{color:#E8415C;font-size:28px;line-height:1.25;margin:0 0 18px}'+
        '.__cr-wrap a{color:#E8415C} .__cr-wrap img{max-width:100%;height:auto;border-radius:6px}'+
        '.__cr-wrap p{margin:0 0 1em} .__cr-wrap *{max-width:100%}';
      document.head.appendChild(css);
      document.documentElement.style.background='#0A0506';
      document.body.className='__cr';
      document.body.innerHTML='<div class="__cr-wrap"><h1>'+title+'</h1>'+best.innerHTML+'</div>';
      window.scrollTo(0,0);
    })();
    """
}
