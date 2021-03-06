{-# OPTIONS_GHC -Wno-unused-matches #-}
{-# LANGUAGE QuasiQuotes #-}

module Handler.NewsletterView where

import Import
import qualified Text.HTML.Fscraper as F
import Text.Hamlet (hamletFile)
import Yadata.LibAPI as YL


getNewsletterViewR :: Handler Html
getNewsletterViewR = do
  now <- liftIO getCurrentTime
  allStories <- runDB $ selectList [] [Desc StoryCreated, LimitTo 10]
  liftIO $
    YL.createGraphForNewsletter
      ["IBM", "MSFT", "AAPL", "KO"]
      "static/newsletter-graph.jpg"
  let issue = "1" :: Text
  newsletterLayout $ do
    setTitle "Investments info"
    toWidget
      [whamlet|
    <table border="0" cellpadding="0" cellspacing="0" .body>
      <tr>
        <td>&nbsp;
        <td .container>
          <div .content>
            <table .main>
              <tr>
                <td .wrapper>
                  <span style="float:right">Issue ##{issue}
                  <h2>Investments Info newsletter
              <tr>
                <td .wrapper>
                 $forall Entity _ Story{..} <- allStories
                  <table border="0" cellpadding="0" cellspacing="0">
                    <tr>
                      <td>
                        <p><a href=#{(pack F.reutersUrl) <> storyLink} target=_blank> #{storyTitle}
              <tr>
                <td .wrapper>
                   <img style="width:500px;" src="https://investments-info.com/static/newsletter-graph.jpg">
              <tr>
                <td .wrapper>
                   <a href="https://investments-info.com/newsletter/view">view on website
            <div .footer>
              <table border="0" cellpadding="0" cellspacing="0">
                <tr>
                  <td .content-block .powered-by>
                    <a href="https://investments-info.com">investments-info.com

        <td>&nbsp;
|]

newsletterLayout :: Widget -> Handler Html
newsletterLayout widget = do
  master <- getYesod
  pc <- widgetToPageContent $(widgetFile "newsletter-layout")
  withUrlRenderer
    $(hamletFile "templates/layout/newsletter-layout-wrapper.hamlet")
